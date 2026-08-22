import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class ContinuousBlockEditorTextView: NSTextView, NSTextViewDelegate {
    private weak var editorSession: BlockEditorSession?
    private var hostToken: UUID?
    private var applyingProjection = false
    private var executingComposingTextSystemCommand = false
    private var projectedDocumentIsVisiblyEmpty = true
    private var currentProjection: BlockDocumentTextProjection?
    private var finishingComposition = false
    private var processingDirectSelectionInput = false
    private var pendingDirectSelectionRange: NSRange?
    private var auxiliaryControlSelectionRange: NSRange?
    private var markedCandidate: String?
    private var pointerAnchorUTF16Offset: Int?
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private let ownedTextContainer: NSTextContainer
    private(set) var immediateInsertionIndicator = NSTextInsertionIndicator(frame: .zero)
    private(set) var fullProjectionApplyCount = 0
    private(set) var diffProjectionApplyCount = 0
    private(set) var selectionRevealRequestCount = 0
    private var selectionRevealTask: Task<Void, Never>?

    convenience init() { self.init(frame: .zero) }

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

    var authoritativeUndoManager: UndoManager? { editorSession?.undoManager }
    var attachedSession: BlockEditorSession? { editorSession }
    var isPresentingEmptyDocumentPlaceholder: Bool {
        projectedDocumentIsVisiblyEmpty
            && !hasMarkedText()
    }

    func install(session: BlockEditorSession, hostToken: UUID) {
        editorSession = session
        self.hostToken = hostToken
        setAccessibilityIdentifier("continuous-block-editor")
    }

    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        guard !applyingProjection else { return }
        applyingProjection = true
        defer { applyingProjection = false }
        currentProjection = projection
        projectedDocumentIsVisiblyEmpty = projection.document.blocks.allSatisfy { block in
            block.kind == .paragraph && block.inlineContent.spans.allSatisfy(\.text.isEmpty)
        }

        if let diff,
           !finishingComposition,
           !hasMarkedText(),
           NSMaxRange(diff.oldRange) <= (textStorage?.length ?? 0) {
            applyBoundedProjectionDiff(diff)
            // NSTextStorage is allowed to add private typing/layout
            // attributes, so whole attributed-string equality is not a sound
            // signal that a bounded edit failed. Character equality is the
            // structural invariant; the changed run and caret neighbourhood
            // are restored from the authoritative projection below.
            if textStorage?.string == projection.attributedString.string {
                diffProjectionApplyCount += 1
            } else {
                textStorage?.setAttributedString(projection.attributedString)
                fullProjectionApplyCount += 1
            }
        } else if textStorage?.string != projection.attributedString.string {
            textStorage?.setAttributedString(projection.attributedString)
            fullProjectionApplyCount += 1
        }
        if isValid(selectedRange, length: projection.attributedString.length) {
            self.selectedRange = selectedRange
            restoreAuthoritativeAttributes(
                projection: projection,
                selectedRange: selectedRange
            )
        }
        updateImmediateInsertionIndicator()
        needsDisplay = true
        requestSelectionRevealIfFocused()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isPresentingEmptyDocumentPlaceholder {
            ("开始写点什么…" as NSString).draw(
                at: textContainerOrigin,
                withAttributes: [
                    .font: BlockTextStyle.baseFont(for: .paragraph),
                    .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72)
                ]
            )
        }
        drawStructuralDecorations()
    }

    override func layout() {
        super.layout()
        updateImmediateInsertionIndicator()
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        let font = insertionPointFont(at: selectedRange.location)
        let glyphHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(rect.height, glyphHeight)
        let alignedRect = NSRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        )
        super.drawInsertionPoint(in: alignedRect, color: color, turnedOn: flag)
    }

    private func drawStructuralDecorations() {
        guard let projectedDocument = currentProjection?.document else { return }
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.82)
        var orderedIndex = 0
        for (index, block) in projectedDocument.blocks.enumerated() {
            if block.kind == .ordered {
                orderedIndex = index > 0 && projectedDocument.blocks[index - 1].kind == .ordered
                    ? orderedIndex + 1
                    : 1
            } else {
                orderedIndex = 0
            }
            let structuralIndent = CGFloat(block.indentLevel * 20)
            guard let markerBaseline = structuralMarkerBaselineY(forBlockAt: index) else { continue }
            let markerFont = markerFont(for: block.kind)
            let drawOrigin = NSPoint(
                x: textContainerOrigin.x + structuralIndent + 1,
                y: markerBaseline - markerFont.ascender
            )
            switch block.kind {
            case .bullet:
                ("•" as NSString).draw(at: drawOrigin, withAttributes: markerAttributes(font: markerFont, color: color))
            case .ordered:
                ("\(orderedIndex)." as NSString).draw(
                    at: drawOrigin,
                    withAttributes: markerAttributes(font: markerFont, color: color)
                )
            case .task:
                break
            case .quote:
                let line = lineFragmentRect(forBlockAt: index)
                color.setFill()
                NSBezierPath(rect: .init(
                    x: textContainerOrigin.x + structuralIndent + 4,
                    y: line.minY + textContainerOrigin.y,
                    width: 2,
                    height: max(18, line.height)
                )).fill()
            case .divider:
                let line = lineFragmentRect(forBlockAt: index)
                color.withAlphaComponent(0.48).setStroke()
                let path = NSBezierPath()
                let y = line.midY + textContainerOrigin.y
                path.move(to: .init(x: textContainerOrigin.x, y: y))
                path.line(to: .init(x: max(textContainerOrigin.x, bounds.width - textContainerOrigin.x), y: y))
                path.lineWidth = 1
                path.stroke()
            case .paragraph, .heading1, .heading2, .heading3, .code, .link:
                break
            }
        }
    }

    func structuralMarkerBaselineY(for blockID: BlockID) -> CGFloat? {
        guard let projection = currentProjection,
              let index = projection.document.blocks.firstIndex(where: { $0.id == blockID }) else {
            return nil
        }
        return structuralMarkerBaselineY(forBlockAt: index)
    }

    private func structuralMarkerBaselineY(forBlockAt index: Int) -> CGFloat? {
        guard let projection = currentProjection,
              projection.document.blocks.indices.contains(index) else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let segment = projection.segments[index]
        let origin = textContainerOrigin

        if segment.contentRange.length > 0, ownedLayoutManager.numberOfGlyphs > 0 {
            let glyphIndex = ownedLayoutManager.glyphIndexForCharacter(at: segment.contentRange.location)
            let line = ownedLayoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = ownedLayoutManager.location(forGlyphAt: glyphIndex)
            return origin.y + line.minY + glyphLocation.y
        }

        let line = lineFragmentRect(forBlockAt: index)
        let font = BlockTextStyle.baseFont(for: projection.document.blocks[index].kind)
        let glyphHeight = font.ascender - font.descender
        return origin.y + line.minY + max(0, (line.height - glyphHeight) / 2) + font.ascender
    }

    private func lineFragmentRect(forBlockAt index: Int) -> NSRect {
        guard let projection = currentProjection,
              projection.document.blocks.indices.contains(index) else {
            return .init(x: 0, y: 0, width: bounds.width, height: 24)
        }
        let location = projection.segments[index].displayRange.location
        let textLength = textStorage?.length ?? 0
        if location == textLength,
           !ownedLayoutManager.extraLineFragmentUsedRect.isEmpty {
            return ownedLayoutManager.extraLineFragmentUsedRect
        }
        guard ownedLayoutManager.numberOfGlyphs > 0, textLength > 0 else {
            return .init(x: 0, y: 0, width: bounds.width, height: 24)
        }
        let characterIndex = min(location, max(0, textLength - 1))
        let glyphIndex = ownedLayoutManager.glyphIndexForCharacter(at: characterIndex)
        return ownedLayoutManager.lineFragmentUsedRect(
            forGlyphAt: min(glyphIndex, max(0, ownedLayoutManager.numberOfGlyphs - 1)),
            effectiveRange: nil
        )
    }

    private func markerFont(for kind: BlockKind) -> NSFont {
        let bodyFont = BlockTextStyle.baseFont(for: kind)
        return NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .regular)
    }

    private func markerAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color
        ]
    }

    func measuredContentHeight(for width: CGFloat) -> CGFloat {
        ownedTextContainer.containerSize = .init(
            width: max(1, width - textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        return ceil(ownedLayoutManager.usedRect(for: ownedTextContainer).height)
            + textContainerInset.height * 2
    }

    func utf16Offset(at point: NSPoint) -> Int? {
        guard !string.isEmpty else { return 0 }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = ownedLayoutManager.glyphIndex(
            for: containerPoint,
            in: ownedTextContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let characterRange = ownedLayoutManager.characterRange(
            forGlyphRange: .init(location: glyph, length: 1),
            actualGlyphRange: nil
        )
        // The exact glyph midpoint belongs to the leading insertion point;
        // only the trailing half advances. This keeps hit-testing stable for
        // composed emoji while still sending far-right clicks to line end.
        let insertion = fraction > 0.5 ? NSMaxRange(characterRange) : characterRange.location
        return min(
            max(insertion, 0),
            string.utf16.count
        )
    }

    func windowPoint(forUTF16Offset offset: Int) -> NSPoint? {
        guard offset >= 0, offset < string.utf16.count else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let glyph = ownedLayoutManager.glyphIndexForCharacter(at: offset)
        let rect = ownedLayoutManager.boundingRect(
            forGlyphRange: .init(location: glyph, length: 1),
            in: ownedTextContainer
        )
        guard !rect.isEmpty else { return nil }
        let origin = textContainerOrigin
        return convert(.init(x: origin.x + rect.midX, y: origin.y + rect.midY), to: nil)
    }

    func taskCheckboxFrame(for blockID: BlockID) -> NSRect? {
        guard let projection = currentProjection,
              let index = projection.document.blocks.firstIndex(where: { $0.id == blockID }),
              projection.document.blocks[index].kind == .task else { return nil }
        let block = projection.document.blocks[index]
        let line = lineFragmentRect(forBlockAt: index)
        return .init(
            x: textContainerOrigin.x + CGFloat(block.indentLevel * 20),
            y: textContainerOrigin.y + line.minY + max(0, (line.height - 18) / 2),
            width: 18,
            height: 18
        )
    }

    @discardableResult
    func beginPointerSelection(atUTF16Offset offset: Int) -> Bool {
        guard offset >= 0 else { return false }
        do {
            pointerAnchorUTF16Offset = offset
            try editorSession?.adoptNativeSelection(
                .init(location: offset, length: 0),
                direction: .forward,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            pointerAnchorUTF16Offset = nil
            return false
        }
    }

    @discardableResult
    func extendPointerSelection(toUTF16Offset offset: Int) -> Bool {
        guard let anchor = pointerAnchorUTF16Offset, offset >= 0 else { return false }
        let range = NSRange(location: min(anchor, offset), length: max(anchor, offset) - min(anchor, offset))
        do {
            try editorSession?.adoptNativeSelection(
                range,
                direction: offset >= anchor ? .forward : .reverse,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            return false
        }
    }

    @discardableResult
    func extendSelectionWithShift(toUTF16Offset offset: Int) -> Bool {
        do {
            try editorSession?.extendNativeSelection(
                toUTF16Offset: offset,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if let hostToken { editorSession?.beginNativeInputEvent(hostToken: hostToken) }
        if pendingDirectSelectionRange != nil {
            editorSession?.synchronizePendingDirectSelection()
        }
        processingDirectSelectionInput = true
        defer { processingDirectSelectionInput = false }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        processingDirectSelectionInput = true
        defer { processingDirectSelectionInput = false }
        super.mouseDown(with: event)
    }

    override func setAccessibilitySelectedTextRange(_ selectedTextRange: NSRange) {
        rememberDirectSelection(selectedTextRange)
        processingDirectSelectionInput = true
        defer { processingDirectSelectionInput = false }
        super.setAccessibilitySelectedTextRange(selectedTextRange)
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        if attribute == .selectedTextRange,
           let value = value as? NSValue {
            let range = value.rangeValue
            MainActor.assumeIsolated {
                rememberDirectSelection(range)
            }
        }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            needsDisplay = true
            updateImmediateInsertionIndicator()
            if let hostToken { editorSession?.focus(hostToken: hostToken) }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            needsDisplay = true
            immediateInsertionIndicator.displayMode = .hidden
            if let hostToken { editorSession?.blur(hostToken: hostToken) }
        }
        return result
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProjection,
              !finishingComposition,
              auxiliaryControlSelectionRange == nil,
              editorSession?.isComposing != true else { return }
        if selectedRange.length > 0,
           pendingDirectSelectionRange?.length ?? -1 < selectedRange.length {
            // Mouse drag and some AX clients report a growing sequence of
            // native ranges through the delegate rather than the setter.
            pendingDirectSelectionRange = selectedRange
        }
        // AppKit can publish a transient caret while a formatting control is
        // activating. Only a direct editor mouse/key/AX action may collapse a
        // non-empty authoritative range.
        guard selectedRange.length > 0
            || processingDirectSelectionInput
            || !authoritativeSelectionIsNonEmpty else { return }
        try? editorSession?.adoptSelectionFromNativeTextView(
            selectedRange,
            typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
        )
        updateImmediateInsertionIndicator()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !applyingProjection, let editorSession, let hostToken else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        guard editorSession.beginContinuousComposition(
            replacementRange: replacementRange,
            hostToken: hostToken
        ) != nil else {
            editorSession.projectAuthoritativeState()
            return
        }
        prepareTypingAttributesForEmptyBlockComposition(at: self.selectedRange.location)
        markedCandidate = Self.string(from: string)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updateImmediateInsertionIndicator()
        needsDisplay = true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if executingComposingTextSystemCommand {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard !applyingProjection,
              let value = Self.string(from: insertString),
              let editorSession,
              let hostToken else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        finishingComposition = editorSession.isComposing
        let handled = editorSession.dispatchNativeReplacement(
            range: replacementRange,
            replacement: value,
            hostToken: hostToken
        )
        markedCandidate = nil
        finishingComposition = false
        if !handled { editorSession.projectAuthoritativeState() }
    }

    override func unmarkText() {
        guard let editorSession, let hostToken, editorSession.isComposing else {
            super.unmarkText()
            return
        }
        let value = markedCandidate ?? ""
        finishingComposition = true
        defer { finishingComposition = false }
        super.unmarkText()
        editorSession.commitComposition(value, hostToken: hostToken)
        markedCandidate = nil
    }

    override func cancelOperation(_ sender: Any?) {
        if let editorSession, let hostToken, editorSession.isComposing {
            finishingComposition = true
            editorSession.cancelComposition(hostToken: hostToken, terminalValue: markedCandidate)
            markedCandidate = nil
            finishingComposition = false
            return
        }
        if editorSession?.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == true { return }
        super.cancelOperation(sender)
    }

    override func doCommand(by selector: Selector) {
        if editorSession?.isComposing == true {
            executingComposingTextSystemCommand = true
            defer { executingComposingTextSystemCommand = false }
            super.doCommand(by: selector)
            return
        }
        if editorSession?.handleSlashSelector(selector) == true { return }
        if Self.isNativeSelectionCommand(selector) {
            super.doCommand(by: selector)
            return
        }
        if let command = Self.command(for: selector), let editorSession {
            if let outcome = editorSession.dispatchTextCommandOutcome(command) {
                if case .none = outcome.result.mutation,
                   Self.moveFocusForUnhandledIndentation(selector, from: self) {
                    return
                }
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

    override func copy(_ sender: Any?) {
        if pendingDirectSelectionRange != nil { editorSession?.synchronizePendingDirectSelection() }
        if editorSession?.copy() == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let editorSession {
            if pendingDirectSelectionRange != nil { editorSession.synchronizePendingDirectSelection() }
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
            editorSession?.synchronizePendingDirectSelection()
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.bold))
        case "i":
            editorSession?.synchronizePendingDirectSelection()
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.italic))
        case "c" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift):
            editorSession?.synchronizePendingDirectSelection()
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.code))
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func configure() {
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = BlockTextStyle.lineFragmentPadding
        textContainerInset = .init(width: 0, height: 8)
        insertionPointColor = .clear
        immediateInsertionIndicator.displayMode = .hidden
        immediateInsertionIndicator.color = .textInsertionPointColor
        addSubview(immediateInsertionIndicator)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("笔记正文")
        setAccessibilityPlaceholderValue("开始写点什么…")
        delegate = self
    }

    private func updateImmediateInsertionIndicator() {
        guard window?.firstResponder === self,
              selectedRange.length == 0,
              let geometry = immediateInsertionPointGeometry(at: selectedRange.location) else {
            immediateInsertionIndicator.displayMode = .hidden
            return
        }
        immediateInsertionIndicator.frame = NSRect(
            x: geometry.x,
            y: geometry.baseline - geometry.font.ascender,
            width: 1,
            height: ceil(geometry.font.ascender - geometry.font.descender)
        )
        immediateInsertionIndicator.displayMode = .automatic
    }

    private func immediateInsertionPointGeometry(
        at utf16Offset: Int
    ) -> (x: CGFloat, baseline: CGFloat, font: NSFont)? {
        guard utf16Offset >= 0, utf16Offset <= ownedTextStorage.length else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let origin = textContainerOrigin
        let font = insertionPointFont(at: utf16Offset)

        if !hasMarkedText(),
           let projection = currentProjection,
           let emptyBlockIndex = projection.segments.firstIndex(where: {
               $0.contentRange.length == 0 && $0.contentRange.location == utf16Offset
           }) {
            let block = projection.document.blocks[emptyBlockIndex]
            let line = utf16Offset == ownedTextStorage.length
                && !ownedLayoutManager.extraLineFragmentUsedRect.isEmpty
                ? ownedLayoutManager.extraLineFragmentUsedRect
                : lineFragmentRect(forBlockAt: emptyBlockIndex)
            let glyphHeight = font.ascender - font.descender
            let textStart = BlockTextStyle.textColumnOffset(
                for: block.kind,
                indentLevel: block.indentLevel
            )
            return (
                x: origin.x + textStart,
                baseline: origin.y + line.minY
                    + max(0, (line.height - glyphHeight) / 2)
                    + font.ascender,
                font: font
            )
        }

        if utf16Offset == ownedTextStorage.length,
           !hasMarkedText(),
           !ownedLayoutManager.extraLineFragmentUsedRect.isEmpty {
            let line = ownedLayoutManager.extraLineFragmentUsedRect
            let glyphHeight = font.ascender - font.descender
            return (
                x: origin.x + line.minX,
                baseline: origin.y + line.minY
                    + max(0, (line.height - glyphHeight) / 2)
                    + font.ascender,
                font: font
            )
        }

        if ownedLayoutManager.numberOfGlyphs > 0, ownedTextStorage.length > 0 {
            let characterIndex = utf16Offset == ownedTextStorage.length
                ? max(0, utf16Offset - 1)
                : utf16Offset
            let glyphIndex = ownedLayoutManager.glyphIndexForCharacter(at: characterIndex)
            let line = ownedLayoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = ownedLayoutManager.location(forGlyphAt: glyphIndex)
            let glyphRect = ownedLayoutManager.boundingRect(
                forGlyphRange: .init(location: glyphIndex, length: 1),
                in: ownedTextContainer
            )
            return (
                x: origin.x + (utf16Offset == ownedTextStorage.length ? glyphRect.maxX : glyphRect.minX),
                baseline: origin.y + line.minY + glyphLocation.y,
                font: font
            )
        }

        let line = ownedLayoutManager.extraLineFragmentUsedRect.isEmpty
            ? NSRect(x: 0, y: 0, width: 0, height: ceil((font.ascender - font.descender) * 1.45))
            : ownedLayoutManager.extraLineFragmentUsedRect
        let glyphHeight = font.ascender - font.descender
        return (
            x: origin.x + line.minX,
            baseline: origin.y + line.minY + max(0, (line.height - glyphHeight) / 2) + font.ascender,
            font: font
        )
    }

    private func insertionPointFont(at utf16Offset: Int) -> NSFont {
        let segment = currentProjection?.segments.first(where: {
            utf16Offset >= $0.contentRange.location
                && utf16Offset <= NSMaxRange($0.contentRange)
        })
        if let textStorage,
           let segment,
           segment.contentRange.length > 0 {
            let attributeOffset = min(
                max(utf16Offset - 1, segment.contentRange.location),
                NSMaxRange(segment.contentRange) - 1
            )
            if let font = textStorage.attribute(
                .font,
                at: attributeOffset,
                effectiveRange: nil
            ) as? NSFont {
                return font
            }
        }
        if ownedTextStorage.length > 0 {
            let attributeOffset = min(max(utf16Offset - 1, 0), ownedTextStorage.length - 1)
            if let font = ownedTextStorage.attribute(
                .font,
                at: attributeOffset,
                effectiveRange: nil
            ) as? NSFont {
                return font
            }
        }
        return BlockTextStyle.baseFont(for: segment?.kind ?? .paragraph)
    }

    private var authoritativeSelectionIsNonEmpty: Bool {
        guard let editorSession,
              let currentProjection,
              let range = try? currentProjection.nsRange(for: editorSession.selection) else { return false }
        return range.length > 0
    }

    func consumePendingDirectSelection() -> NSRange? {
        defer { pendingDirectSelectionRange = nil }
        return pendingDirectSelectionRange
    }

    func beginAuxiliaryControlActivation() -> NSRange {
        if let auxiliaryControlSelectionRange { return auxiliaryControlSelectionRange }
        let range = consumePendingDirectSelection() ?? selectedRange
        auxiliaryControlSelectionRange = range
        return range
    }

    func endAuxiliaryControlActivation() {
        auxiliaryControlSelectionRange = nil
        pendingDirectSelectionRange = nil
    }

    var isHandlingAuxiliaryControl: Bool { auxiliaryControlSelectionRange != nil }

    private func rememberDirectSelection(_ range: NSRange) {
        if range.length == 0 {
            pendingDirectSelectionRange = range
        } else if pendingDirectSelectionRange?.length ?? -1 < range.length {
            // AX text selection can arrive as a full range followed by one or
            // more smaller fragments. Keep the largest range from that direct
            // interaction until the user's next command consumes it.
            pendingDirectSelectionRange = range
        }
    }

    private func applyBoundedProjectionDiff(_ diff: BlockDocumentProjectionDiff) {
        guard let textStorage else { return }
        let existing = textStorage.attributedSubstring(from: diff.oldRange)
        if diff.oldRange.length == diff.replacement.length,
           existing.string == diff.replacement.string {
            textStorage.beginEditing()
            diff.replacement.enumerateAttributes(
                in: NSRange(location: 0, length: diff.replacement.length),
                options: []
            ) { attributes, range, _ in
                textStorage.setAttributes(
                    attributes,
                    range: NSRange(
                        location: diff.oldRange.location + range.location,
                        length: range.length
                    )
                )
            }
            textStorage.endEditing()
        } else {
            textStorage.replaceCharacters(in: diff.oldRange, with: diff.replacement)
        }
    }

    func requestSelectionRevealIfFocused() {
        guard window?.firstResponder === self else { return }
        selectionRevealRequestCount += 1
        selectionRevealTask?.cancel()
        selectionRevealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.window?.firstResponder === self else { return }
            // scrollRangeToVisible asks TextKit for the caret's local layout.
            // Forcing ensureLayout on the entire 50k-character container here
            // made every focused keystroke pay the whole-document cost.
            self.scrollRangeToVisible(self.selectedRange)
            self.selectionRevealTask = nil
        }
    }

    private struct TextSystem {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    private static func makeTextSystem() -> TextSystem {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return .init(storage: storage, layoutManager: layoutManager, container: container)
    }

    private func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.location <= length - range.length
    }

    private func restoreAuthoritativeAttributes(
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        guard let textStorage, projection.attributedString.length > 0 else { return }
        var ranges: [NSRange] = []
        let selectionStart = max(0, selectedRange.location - 1)
        let selectionEnd = min(
            projection.attributedString.length,
            NSMaxRange(selectedRange) + 1
        )
        if selectionEnd > selectionStart {
            ranges.append(.init(location: selectionStart, length: selectionEnd - selectionStart))
        }
        textStorage.beginEditing()
        let available = NSRange(location: 0, length: min(
            textStorage.length,
            projection.attributedString.length
        ))
        for proposedRange in ranges {
            let range = NSIntersectionRange(proposedRange, available)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            textStorage.setAttributes([:], range: range)
            projection.attributedString.enumerateAttributes(in: range, options: []) {
                attributes, attributeRange, _ in
                textStorage.setAttributes(attributes, range: attributeRange)
            }
        }
        textStorage.endEditing()
    }

    private func prepareTypingAttributesForEmptyBlockComposition(at utf16Offset: Int) {
        guard let projection = currentProjection,
              let index = projection.segments.firstIndex(where: {
                  $0.contentRange.length == 0 && $0.contentRange.location == utf16Offset
              }) else { return }
        let block = projection.document.blocks[index]
        var attributes = typingAttributes
        attributes[.font] = BlockTextStyle.styledFont(
            base: BlockTextStyle.baseFont(for: block.kind),
            marks: editorSession?.currentTypingAttributes.marks ?? []
        )
        attributes[.paragraphStyle] = BlockTextStyle.paragraphStyle(
            for: block.kind,
            indentLevel: block.indentLevel
        )
        attributes[.jellyBlockID] = block.id.rawValue.uuidString
        attributes[.jellyBlockKind] = block.kind.rawValue
        typingAttributes = attributes
    }

    private static func command(for selector: Selector) -> BlockInputCommand? {
        switch selector.description {
        case "insertNewline:": .enter
        case "insertLineBreak:": .softBreak
        case "deleteBackward:": .backspace
        case "insertTab:": .indent
        case "insertBacktab:": .outdent
        default: nil
        }
    }

    private static func moveFocusForUnhandledIndentation(
        _ selector: Selector,
        from textView: NSTextView
    ) -> Bool {
        switch selector.description {
        case "insertTab:":
            textView.window?.selectNextKeyView(textView)
            return true
        case "insertBacktab:":
            textView.window?.selectPreviousKeyView(textView)
            return true
        default:
            return false
        }
    }

    private static func isNativeSelectionCommand(_ selector: Selector) -> Bool {
        selector.description.hasPrefix("move")
    }

    private static func string(from value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }
}
