import AppKit
import Combine
import Foundation
import WorkspaceDomain

enum BlockEditorSaveStatus: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

struct BlockEditorDispatchOutcome: Equatable, Sendable {
    let result: BlockInputResult
    let commandHandled: Bool
}

@MainActor
protocol BlockEditorSessionContract: AnyObject {
    var noteID: NoteID { get }
    var editSessionID: UUID { get }
    var undoManager: UndoManager { get }
    var document: BlockDocument { get }
    var selection: BlockEditorSelection { get }
    func attach(blockID: BlockID, hostToken: UUID, textView: BlockEditorTextView)
    func detach(hostToken: UUID)
    func dispatch(_ command: BlockInputCommand) throws -> BlockEditorDispatchOutcome
    func autosaveDidResolve(_ status: BlockEditorSaveStatus)
}

enum BlockEditorIntegrationError: Error, Equatable, Sendable {
    case illegalResult
    case clipboardWriteFailed
}

@MainActor
final class BlockEditorSession: ObservableObject, BlockEditorSessionContract {
    let noteID: NoteID
    let editSessionID: UUID
    let undoManager: UndoManager
    @Published private(set) var document: BlockDocument
    @Published private(set) var selection: BlockEditorSelection
    @Published private(set) var saveStatus: BlockEditorSaveStatus = .idle
    @Published private(set) var slashMenuState: BlockSlashMenuState?

    private let focusRegistry: EditorFocusRegistry
    private let onDocumentChange: (BlockDocument) -> Void
    private let pasteboardAdapter: BlockPasteboardAdapter
    private let selectionController: BlockSelectionController
    private var hosts: [UUID: HostLease] = [:]
    private var activeHostTokens: [BlockID: UUID] = [:]
    private weak var continuousHost: (any ContinuousBlockEditorHost)?
    private var continuousHostToken: UUID?
    private var continuousProjection: BlockDocumentTextProjection?
    private var typingRecord: TypingUndoRecord?
    private var composition: CompositionBaseline?
    private var compositionGeneration: UInt = 0
    private var terminalComposition: TerminalComposition?
    private var isProjecting = false
    private var editorRevision: UInt = 0
    private var dismissedSlash: DismissedSlash?

    init(
        noteID: NoteID,
        editSessionID: UUID,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        document = initialDocument
        selection = initialSelection
        self.focusRegistry = focusRegistry
        self.onDocumentChange = onDocumentChange
        undoManager = UndoManager()
        pasteboardAdapter = BlockPasteboardAdapter()
        selectionController = BlockSelectionController(selection: initialSelection)
    }

    func attach(blockID: BlockID, hostToken: UUID, textView: BlockEditorTextView) {
        if let replacedToken = activeHostTokens[blockID], replacedToken != hostToken {
            if composition?.hostToken == replacedToken {
                cancelComposition(hostToken: replacedToken)
            }
            hosts.removeValue(forKey: replacedToken)
            focusRegistry.clear(ownerID: replacedToken)
        }
        hosts[hostToken] = HostLease(blockID: blockID, token: hostToken, textView: textView)
        activeHostTokens[blockID] = hostToken
        textView.install(session: self, blockID: blockID, hostToken: hostToken)
        projectAuthoritativeState()
    }

    func attach(host: any ContinuousBlockEditorHost, hostToken: UUID) {
        if continuousHost === host, continuousHostToken == hostToken {
            return
        }
        if let previousToken = continuousHostToken, previousToken != hostToken {
            if composition?.hostToken == previousToken {
                cancelComposition(hostToken: previousToken)
            }
            focusRegistry.clear(ownerID: previousToken)
            continuousProjection = nil
        }
        continuousHost = host
        continuousHostToken = hostToken
        host.textView.install(session: self, hostToken: hostToken)
        projectAuthoritativeState()
    }

    func detachContinuousHost(hostToken: UUID) {
        guard continuousHostToken == hostToken else { return }
        if composition?.hostToken == hostToken { cancelComposition(hostToken: hostToken) }
        continuousHost = nil
        continuousHostToken = nil
        continuousProjection = nil
        focusRegistry.clear(ownerID: hostToken)
    }

    func detach(hostToken: UUID) {
        guard let lease = hosts[hostToken] else { return }
        if composition?.hostToken == hostToken { cancelComposition(hostToken: hostToken) }
        hosts.removeValue(forKey: hostToken)
        if activeHostTokens[lease.blockID] == hostToken { activeHostTokens[lease.blockID] = nil }
        focusRegistry.clear(ownerID: hostToken)
    }

    func focus(hostToken: UUID) {
        guard isActiveHost(hostToken) || continuousHostToken == hostToken else { return }
        focusRegistry.register(undoManager, ownerID: hostToken)
    }

    func blur(hostToken: UUID) {
        focusRegistry.clear(ownerID: hostToken)
    }

    func dispatch(_ command: BlockInputCommand) throws -> BlockEditorDispatchOutcome {
        let result = try BlockInputReducer.reduce(
            document,
            selection: selection,
            command: command,
            environment: .init(isComposingText: composition != nil, idSource: .random)
        )
        return try consume(result)
    }

    func autosaveDidResolve(_ status: BlockEditorSaveStatus) {
        saveStatus = status
    }

    func projectAuthoritativeState() {
        guard !isProjecting else { return }
        isProjecting = true
        defer { isProjecting = false }
        if let continuousHost {
            let projection = BlockDocumentTextProjection(
                document: document,
                appearance: continuousHost.semanticAppearance,
                completionDescriptionWidth: continuousHost.completionDescriptionWidth
            )
            let range = (try? projection.nsRange(for: selection))
                ?? .init(location: projection.attributedString.length, length: 0)
            let diff = continuousProjection.map {
                BlockDocumentProjectionDiff.make(from: $0, to: projection)
            } ?? nil
            continuousHost.apply(diff: diff, projection: projection, selectedRange: range)
            continuousProjection = projection
        }
        for lease in hosts.values {
            guard let view = lease.textView else { continue }
            guard let block = document.blocks.first(where: { $0.id == lease.blockID }) else { continue }
            let text = Self.text(block)
            let range = BlockSelectionController(selection: selection).projectedRange(for: lease.blockID, document: document)
                ?? .init(location: text.utf16.count, length: 0)
            view.applyAuthoritativeProjection(
                block: block,
                selectedRange: range,
                isSelected: isSelectionIncluding(blockID: lease.blockID)
            )
        }
    }

    var selectionContainsLink: Bool {
        guard let range = normalizedFormattingRange(), range.start != range.end else { return false }
        for index in range.lowerIndex...range.upperIndex {
            let block = document.blocks[index]
            let lower = index == range.lowerIndex ? range.start.graphemeOffset : 0
            let upper = index == range.upperIndex ? range.end.graphemeOffset : Self.text(block).count
            var cursor = 0
            for span in block.inlineContent.spans {
                let spanEnd = cursor + span.text.count
                if upper > cursor, lower < spanEnd,
                   let link = span.linkURL, BlockURLValidator.isValid(link) {
                    return true
                }
                cursor = spanEnd
            }
        }
        return false
    }

    var focusedTaskBlockID: BlockID? {
        let blockID: BlockID
        switch selection {
        case let .text(_, focus, _, _): blockID = focus.blockID
        case let .blocks(_, focus): blockID = focus
        }
        return document.blocks.first(where: {
            $0.id == blockID && $0.kind == .task
        })?.id
    }

    @discardableResult
    func beginComposition(blockID: BlockID, replacementRange: NSRange, hostToken: UUID) -> UInt? {
        if let composition {
            return composition.hostToken == hostToken ? composition.token : nil
        }
        guard isActiveHost(hostToken), hosts[hostToken]?.blockID == blockID else { return nil }
        guard let replacement = compositionSelection(blockID: blockID, replacementRange: replacementRange) else { return nil }
        slashMenuState = nil
        terminalComposition = nil
        compositionGeneration &+= 1
        composition = .init(
            document: document,
            originalSelection: selection,
            replacementSelection: replacement,
            blockID: blockID,
            hostToken: hostToken,
            token: compositionGeneration
        )
        return compositionGeneration
    }

    func commitComposition(_ value: String, hostToken: UUID) {
        guard let baseline = composition, baseline.hostToken == hostToken else { return }
        composition = nil
        terminalComposition = .init(token: baseline.token, hostToken: hostToken, value: value)
        document = baseline.document
        applySelection(baseline.replacementSelection, incrementingRevision: false, project: false)
        do { _ = try dispatch(.insertTextApplyingMarkdownShortcut(value)) } catch { projectAuthoritativeState() }
    }

    func cancelComposition(hostToken: UUID, terminalValue: String? = nil) {
        guard let baseline = composition, baseline.hostToken == hostToken else { return }
        composition = nil
        terminalComposition = .init(token: baseline.token, hostToken: hostToken, value: terminalValue)
        document = baseline.document
        applySelection(baseline.originalSelection, incrementingRevision: false, project: true)
    }

    var isComposing: Bool { composition != nil }

    var currentTypingAttributes: BlockTypingAttributes {
        guard case let .text(_, _, _, attributes) = selection else {
            return .init(marks: [], linkURL: nil)
        }
        return attributes
    }

    var focusedBlockKind: BlockKind? {
        let blockID: BlockID
        switch selection {
        case let .text(_, focus, _, _): blockID = focus.blockID
        case let .blocks(_, focus): blockID = focus
        }
        return document.blocks.first(where: { $0.id == blockID })?.kind
    }

    /// Force the live IME candidate into the authoritative document through the
    /// same commit path as `unmarkText`. Returns false only when a live host
    /// still reports a composition that could not be committed.
    @discardableResult
    func terminallyFinalizeNativeComposition() -> Bool {
        guard let composition else { return true }
        if composition.hostToken == continuousHostToken,
           let textView = continuousHost?.textView {
            if textView.hasMarkedText() {
                textView.unmarkText()
            } else if isComposing {
                commitComposition(textView.string, hostToken: composition.hostToken)
            }
            projectAuthoritativeState()
            return !isComposing
        }
        guard let lease = hosts[composition.hostToken],
              let textView = lease.textView else {
            cancelComposition(hostToken: composition.hostToken)
            return true
        }
        if textView.hasMarkedText() {
            textView.unmarkText()
        } else if isComposing {
            // Marked buffer already cleared but session still holds composition.
            commitComposition(textView.string, hostToken: composition.hostToken)
        }
        projectAuthoritativeState()
        return !isComposing
    }

    var slashOptions: [BlockKind] {
        [.paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .code, .divider]
    }

    func moveSlashSelection(by delta: Int, expected: BlockSlashMenuState) {
        guard slashMenuState == expected else { return }
        slashMenuState?.moveSelection(by: delta, count: slashOptions.count)
    }

    func confirmSlash(kind: BlockKind, expected: BlockSlashMenuState) -> Bool {
        guard slashMenuState == expected, composition == nil else { return false }
        slashMenuState = nil
        do { return try dispatch(.applySlashConversion(kind)).commandHandled } catch { return false }
    }

    func dismissSlashMenu(expected: BlockSlashMenuState) {
        guard slashMenuState == expected else { return }
        dismissedSlash = .init(
            blockID: expected.blockID,
            queryRange: expected.queryRange,
            query: expected.query,
            revision: editorRevision
        )
        slashMenuState = nil
    }

    func handleSlashSelector(_ selector: Selector) -> Bool {
        guard let state = slashMenuState, composition == nil else { return false }
        switch selector.description {
        case "moveUp:":
            moveSlashSelection(by: -1, expected: state)
        case "moveDown:":
            moveSlashSelection(by: 1, expected: state)
        case "insertNewline:":
            return confirmSlash(kind: slashOptions[state.selectedIndex], expected: state)
        case "cancelOperation:":
            dismissSlashMenu(expected: state)
        default:
            return false
        }
        return true
    }

    func dispatchInsertText(_ value: String, blockID: BlockID, replacementRange: NSRange, hostToken: UUID) -> Bool {
        if consumeTerminalDuplicate(value: value, hostToken: hostToken) { return true }
        if composition != nil {
            commitComposition(value, hostToken: hostToken)
            return true
        }
        guard isActiveHost(hostToken),
              let selected = compositionSelection(blockID: blockID, replacementRange: replacementRange) else { return false }
        applySelection(selected, incrementingRevision: false, project: false)
        do { return try dispatch(.insertTextApplyingMarkdownShortcut(value)).commandHandled } catch { return false }
    }

    @discardableResult
    func beginContinuousComposition(replacementRange: NSRange, hostToken: UUID) -> UInt? {
        if let composition {
            return composition.hostToken == hostToken ? composition.token : nil
        }
        guard continuousHostToken == hostToken,
              let replacement = continuousSelection(for: replacementRange) else { return nil }
        slashMenuState = nil
        terminalComposition = nil
        compositionGeneration &+= 1
        let blockID: BlockID
        switch replacement {
        case let .text(_, focus, _, _): blockID = focus.blockID
        case let .blocks(_, focus): blockID = focus
        }
        composition = .init(
            document: document,
            originalSelection: selection,
            replacementSelection: replacement,
            blockID: blockID,
            hostToken: hostToken,
            token: compositionGeneration
        )
        return compositionGeneration
    }

    @discardableResult
    func dispatchNativeReplacement(range: NSRange, replacement: String, hostToken: UUID) -> Bool {
        if consumeTerminalDuplicate(value: replacement, hostToken: hostToken) { return true }
        if composition != nil {
            commitComposition(replacement, hostToken: hostToken)
            return true
        }
        guard continuousHostToken == hostToken,
              let selected = continuousSelection(for: range) else { return false }
        applySelection(selected, incrementingRevision: false, project: false)
        do {
            return try dispatch(.insertTextApplyingMarkdownShortcut(replacement)).commandHandled
        } catch {
            projectAuthoritativeState()
            return false
        }
    }

    func adoptNativeSelection(
        _ range: NSRange,
        direction: SelectionDirection,
        typingAttributes: BlockTypingAttributes
    ) throws {
        guard composition == nil, let projection = currentContinuousProjection() else { return }
        let resolvedAttributes = try resolvedTypingAttributes(
            for: range,
            direction: direction,
            projection: projection,
            fallback: typingAttributes
        )
        closeTypingCoalescing()
        try selectionController.adoptGlobalRange(
            range,
            direction: direction,
            projection: projection,
            typingAttributes: resolvedAttributes
        )
        guard selectionController.selection != selection else { return }
        applySelection(selectionController.selection, incrementingRevision: true, project: true)
    }

    func adoptSelectionFromNativeTextView(
        _ range: NSRange,
        typingAttributes: BlockTypingAttributes
    ) throws {
        guard composition == nil, let projection = currentContinuousProjection() else { return }
        let direction: SelectionDirection
        if case let .text(anchor, _, _, _) = selection,
           range.length > 0,
           try projection.utf16Offset(for: anchor) == NSMaxRange(range) {
            direction = .reverse
        } else {
            direction = .forward
        }
        let resolvedAttributes = try resolvedTypingAttributes(
            for: range,
            direction: direction,
            projection: projection,
            fallback: typingAttributes
        )
        closeTypingCoalescing()
        try selectionController.adoptGlobalRange(
            range,
            direction: direction,
            projection: projection,
            typingAttributes: resolvedAttributes
        )
        guard selectionController.selection != selection else { return }
        // NSTextView has already displayed this selection. Publishing the
        // semantic endpoints must not rebuild attributed text or move the caret.
        applySelection(selectionController.selection, incrementingRevision: true, project: false)
    }

    private func resolvedTypingAttributes(
        for range: NSRange,
        direction: SelectionDirection,
        projection: BlockDocumentTextProjection,
        fallback: BlockTypingAttributes
    ) throws -> BlockTypingAttributes {
        guard range.length == 0,
              (try? projection.nsRange(for: selection)) != range else { return fallback }
        let position = try projection.textPosition(
            atUTF16Offset: range.location,
            affinity: direction == .forward ? .downstream : .upstream
        )
        guard let block = document.blocks.first(where: { $0.id == position.blockID }),
              block.kind != .divider,
              block.kind != .code else {
            return .init(marks: [], linkURL: nil)
        }
        if position.graphemeOffset > 0,
           let span = inlineSpan(
               in: block.inlineContent,
               containingGrapheme: position.graphemeOffset - 1
           ) {
            return .init(
                marks: span.marks,
                linkURL: BlockURLValidator.isValid(span.linkURL) ? span.linkURL : nil
            )
        }
        if let span = inlineSpan(
            in: block.inlineContent,
            containingGrapheme: position.graphemeOffset
        ) {
            return .init(
                marks: span.marks,
                linkURL: BlockURLValidator.isValid(span.linkURL) ? span.linkURL : nil
            )
        }
        return .init(marks: [], linkURL: nil)
    }

    private func inlineSpan(
        in content: InlineContent,
        containingGrapheme target: Int
    ) -> InlineSpan? {
        guard target >= 0 else { return nil }
        var cursor = 0
        for span in content.spans {
            let count = span.text.count
            if target >= cursor, target < cursor + count { return span }
            cursor += count
        }
        return nil
    }

    func extendNativeSelection(
        toUTF16Offset offset: Int,
        typingAttributes: BlockTypingAttributes
    ) throws {
        guard case let .text(anchor, _, _, _) = selection,
              let projection = currentContinuousProjection() else { return }
        let anchorOffset = try projection.utf16Offset(for: anchor)
        let range = NSRange(
            location: min(anchorOffset, offset),
            length: max(anchorOffset, offset) - min(anchorOffset, offset)
        )
        try adoptNativeSelection(
            range,
            direction: offset >= anchorOffset ? .forward : .reverse,
            typingAttributes: typingAttributes
        )
    }

    @discardableResult
    func focusDocumentStart() -> Bool {
        guard let first = document.blocks.first else { return false }
        closeTypingCoalescing()
        applySelection(
            .text(
                anchor: .init(blockID: first.id, graphemeOffset: 0),
                focus: .init(blockID: first.id, graphemeOffset: 0),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            ),
            incrementingRevision: true,
            project: true
        )
        return focusSelectionEndpoint()
    }

    func focusDocumentEnd() {
        guard let last = document.blocks.last else { return }
        closeTypingCoalescing()
        let offset = last.kind == .divider ? 0 : Self.text(last).count
        applySelection(
            .text(
                anchor: .init(blockID: last.id, graphemeOffset: offset),
                focus: .init(blockID: last.id, graphemeOffset: offset),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            ),
            incrementingRevision: true,
            project: true
        )
        if last.kind == .divider {
            _ = dispatchTextCommand(.enter)
        }
        focusSelectionEndpoint()
    }

    func beginNativeInputEvent(hostToken: UUID) {
        guard terminalComposition?.hostToken == hostToken else { return }
        terminalComposition = nil
    }

    func dispatchTextCommand(_ command: BlockInputCommand) -> Bool {
        dispatchTextCommandOutcome(command)?.commandHandled ?? false
    }

    func toggleTaskCompletion(blockID: BlockID, at date: Date) -> Bool {
        guard let block = document.blocks.first(where: { $0.id == blockID }),
              block.kind == .task,
              block.taskState != nil else { return false }
        return dispatchTextCommand(.setTaskCompletion(
            blockID: blockID,
            completedAt: block.taskState?.completedAt == nil ? date : nil
        ))
    }

    func dispatchTextCommandOutcome(_ command: BlockInputCommand) -> BlockEditorDispatchOutcome? {
        guard composition == nil else { return nil }
        return try? dispatch(command)
    }

    func copy() -> Bool { dispatchTextCommand(.copySelection) }
    func cut() -> Bool { dispatchTextCommand(.cutSelection) }
    func paste() -> Bool {
        guard let payload = pasteboardAdapter.readPayload() else { return false }
        return dispatchTextCommand(.replaceSelection(payload))
    }

    func updateNativeSelection(blockID: BlockID, range: NSRange, hostToken: UUID) {
        guard composition == nil, isActiveHost(hostToken), hosts[hostToken]?.blockID == blockID,
              let bridged = try? BlockSelectionBridge.graphemeRange(blockID: blockID, nsRange: range, document: document) else {
            return
        }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        closeTypingCoalescing()
        applySelection(
            .text(anchor: bridged.start, focus: bridged.end, preferredColumn: nil, typingAttributes: attributes),
            incrementingRevision: true,
            project: false
        )
    }

    /// Starts a document-owned selection from a concrete host position. Hosts
    /// never concatenate NSRanges: the session retains the stable-ID endpoints.
    @discardableResult
    func beginPointerSelection(at position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        closeTypingCoalescing()
        selectionController.beginPointer(at: position, attributes: attributes)
        applySyntheticSelection()
        return true
    }

    /// Extends a pointer drag into another attached text host while preserving
    /// the starting anchor and its document direction.
    @discardableResult
    func extendPointerSelection(to position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        selectionController.extendPointer(to: position)
        applySyntheticSelection()
        return true
    }

    /// Shift uses the same anchored extension semantics as a pointer drag.
    @discardableResult
    func extendSelectionWithShift(to position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        selectionController.extendWithShift(to: position)
        applySyntheticSelection()
        return true
    }

    @discardableResult
    func beginBlockSelection(blockID: BlockID) -> Bool {
        guard document.blocks.contains(where: { $0.id == blockID }) else { return false }
        closeTypingCoalescing()
        selectionController.beginBlockSelection(at: blockID)
        applySyntheticSelection()
        return true
    }

    @discardableResult
    func extendBlockSelection(to blockID: BlockID) -> Bool {
        guard document.blocks.contains(where: { $0.id == blockID }) else { return false }
        closeTypingCoalescing()
        selectionController.extendBlockSelection(to: blockID)
        applySyntheticSelection()
        return true
    }

    /// Auxiliary controls temporarily become first responder while they run.
    /// Accessibility-driven selection can update NSTextView without sending
    /// the delegate callback before a toolbar click. Pull that exact native
    /// range first, then restore the editor as command owner afterwards.
    func prepareAuxiliaryControlAction() {
        if let textView = continuousHost?.textView {
            let pendingRange = textView.beginAuxiliaryControlActivation()
            try? adoptSelectionFromNativeTextView(
                pendingRange,
                typingAttributes: currentTypingAttributes
            )
            return
        }
        synchronizeContinuousNativeSelection()
    }

    func performAuxiliaryControlAction(_ action: () -> Void) {
        let textView = continuousHost?.textView
        if textView?.isHandlingAuxiliaryControl != true {
            prepareAuxiliaryControlAction()
        }
        action()
        textView?.endAuxiliaryControlActivation()
        focusSelectionEndpoint()
    }

    func synchronizePendingDirectSelection() {
        guard let textView = continuousHost?.textView,
              let range = textView.consumePendingDirectSelection() else { return }
        try? adoptSelectionFromNativeTextView(
            range,
            typingAttributes: currentTypingAttributes
        )
    }

    private func synchronizeContinuousNativeSelection() {
        guard composition == nil,
              let textView = continuousHost?.textView,
              let projection = currentContinuousProjection(),
              let projected = try? projection.nsRange(for: selection),
              projected != textView.selectedRange else { return }
        if projected.length > 0,
           textView.selectedRange.length == 0 {
            return
        }
        try? adoptSelectionFromNativeTextView(
            textView.selectedRange,
            typingAttributes: currentTypingAttributes
        )
    }

    @discardableResult
    func extendPointerSelection(atWindowPoint point: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        for lease in hosts.values {
            guard let textView = lease.textView, textView.window === window else { continue }
            let localPoint = textView.convert(point, from: nil)
            guard textView.bounds.contains(localPoint),
                  let utf16Offset = textView.utf16Offset(at: localPoint),
                  let position = try? BlockSelectionBridge.graphemePosition(
                      blockID: lease.blockID, utf16Offset: utf16Offset, document: document
                  ) else { continue }
            return extendPointerSelection(to: position, hostToken: lease.token)
        }
        return false
    }

    /// The sole production boundary where reducer outcomes gain AppKit side effects.
    /// Keeping it internal lets the exhaustive matrix verify the exact same path as
    /// `dispatch(_:)`, rather than introducing a test-only alternate implementation.
    func consume(
        _ result: BlockInputResult,
        clipboardWriter: ((BlockClipboardPayload) -> Bool)? = nil
    ) throws -> BlockEditorDispatchOutcome {
        switch (result.mutation, result.effect, result.undo) {
        case (.none, .handled, .none):
            return .init(result: result, commandHandled: true)
        case (.none, .deferToTextSystem, .none):
            return .init(result: result, commandHandled: false)
        case let (.none, .writeClipboard(payload), .none):
            try writeClipboard(payload, using: clipboardWriter)
            return .init(result: result, commandHandled: true)
        case (.none, .handled, .breakCoalescing):
            closeTypingCoalescing()
            return .init(result: result, commandHandled: true)
        case (.selectionOnly, .handled, .none):
            closeTypingCoalescing()
            applySelection(result.selection, incrementingRevision: true, project: true)
            focusSelectionEndpoint()
            return .init(result: result, commandHandled: true)
        case let (.document, .handled, .coalesceTyping(blockID)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            registerTypingUndo(before: before, after: after, blockID: blockID)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        case let (.document, .handled, .atomic(action)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            closeTypingCoalescing()
            registerAtomicUndo(before: before, after: after, action: action)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        case let (.document, .writeClipboard(payload), .atomic(.cut)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            try writeClipboard(payload, using: clipboardWriter)
            closeTypingCoalescing()
            registerAtomicUndo(before: before, after: after, action: .cut)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        default:
            throw BlockEditorIntegrationError.illegalResult
        }
    }

    private func writeClipboard(
        _ payload: BlockClipboardPayload,
        using writer: ((BlockClipboardPayload) -> Bool)?
    ) throws {
        guard (writer?(payload) ?? pasteboardAdapter.write(payload: payload)) else {
            throw BlockEditorIntegrationError.clipboardWriteFailed
        }
    }

    private func registerTypingUndo(before: Snapshot, after: Snapshot, blockID: BlockID) {
        let canContinue: Bool
        if let record = typingRecord,
           record.blockID == blockID,
           record.after.selection == before.selection,
           Self.isContinuousCaret(before.selection, in: blockID) {
            record.after = after
            canContinue = true
        } else {
            canContinue = false
        }
        guard !canContinue else { return }
        closeTypingCoalescing()
        let record = TypingUndoRecord(before: before, after: after, blockID: blockID)
        typingRecord = record
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreTyping(record)
        }
        undoManager.setActionName("输入")
    }

    private func closeTypingCoalescing() { typingRecord = nil }

    private func registerAtomicUndo(before: Snapshot, after: Snapshot, action: BlockUndoAction) {
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: before, inverse: after)
        }
        undoManager.setActionName(action.undoName)
    }

    private func restoreTyping(_ record: TypingUndoRecord) {
        closeTypingCoalescing()
        let inverse = Snapshot(document: document, selection: selection)
        applyDocument(record.before)
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: record.after, inverse: record.before)
        }
        _ = inverse // Documents the inverse capture that keeps snapshot restoration symmetric.
    }

    private func restore(snapshot: Snapshot, inverse: Snapshot) {
        closeTypingCoalescing()
        applyDocument(snapshot)
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: inverse, inverse: snapshot)
        }
    }

    private func applyDocument(_ snapshot: Snapshot) {
        document = snapshot.document
        selection = snapshot.selection
        selectionController.setSelection(snapshot.selection)
        editorRevision &+= 1
        refreshSlashMenu()
        projectAuthoritativeState()
        onDocumentChange(document)
    }

    private func refreshSlashMenu() {
        guard composition == nil,
              case let .text(anchor, focus, _, _) = selection,
              anchor == focus,
              let block = document.blocks.first(where: { $0.id == anchor.blockID }),
              block.kind == .paragraph else {
            slashMenuState = nil
            return
        }
        let text = Self.text(block)
        guard anchor.graphemeOffset >= 0, anchor.graphemeOffset <= text.count else {
            slashMenuState = nil
            return
        }
        let prefix = String(text.prefix(anchor.graphemeOffset))
        guard prefix.hasPrefix("/"), !prefix.dropFirst().contains(where: { $0.isNewline }) else {
            slashMenuState = nil
            return
        }
        let queryRange = 0..<prefix.count
        let query = String(prefix.dropFirst())
        if let dismissedSlash,
           dismissedSlash.blockID == block.id,
           dismissedSlash.queryRange == queryRange,
           dismissedSlash.query == query,
           dismissedSlash.revision == editorRevision {
            slashMenuState = nil
            return
        }
        if let existing = slashMenuState,
           existing.blockID == block.id,
           existing.queryRange == queryRange,
           existing.query == query { return }
        slashMenuState = .open(blockID: block.id, queryRange: queryRange, query: query, revision: editorRevision)
    }

    private func compositionSelection(blockID: BlockID, replacementRange: NSRange) -> BlockEditorSelection? {
        let range: BlockTextRange
        if replacementRange.location == NSNotFound {
            guard case let .text(anchor, focus, _, _) = selection,
                  focus.blockID == blockID else { return nil }
            range = .init(start: anchor, end: focus)
        } else {
            guard let bridged = try? BlockSelectionBridge.graphemeRange(
                blockID: blockID, nsRange: replacementRange, document: document
            ) else { return nil }
            range = bridged
        }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        return .text(anchor: range.start, focus: range.end, preferredColumn: nil, typingAttributes: attributes)
    }

    private func continuousSelection(for range: NSRange) -> BlockEditorSelection? {
        if range.location == NSNotFound { return selection }
        guard let projection = currentContinuousProjection() else { return nil }
        return try? projection.selection(
            for: range,
            preserving: .forward,
            typingAttributes: currentTypingAttributes
        )
    }

    private func currentContinuousProjection() -> BlockDocumentTextProjection? {
        if let continuousProjection, continuousProjection.document == document {
            return continuousProjection
        }
        guard let appearance = continuousHost?.semanticAppearance else { return nil }
        return BlockDocumentTextProjection(
            document: document,
            appearance: appearance,
            completionDescriptionWidth: continuousHost?.completionDescriptionWidth
                ?? NoteEditorLayout.maximumContentWidth - 32
        )
    }

    private static func text(_ block: DocumentBlock) -> String { block.inlineContent.spans.map(\.text).joined() }

    private func normalizedFormattingRange() -> (
        lowerIndex: Int,
        upperIndex: Int,
        start: BlockTextPosition,
        end: BlockTextPosition
    )? {
        guard case let .text(anchor, focus, _, _) = selection,
              let anchorIndex = document.blocks.firstIndex(where: { $0.id == anchor.blockID }),
              let focusIndex = document.blocks.firstIndex(where: { $0.id == focus.blockID }) else { return nil }
        if anchorIndex < focusIndex || (anchorIndex == focusIndex && anchor.graphemeOffset <= focus.graphemeOffset) {
            return (anchorIndex, focusIndex, anchor, focus)
        }
        return (focusIndex, anchorIndex, focus, anchor)
    }

    private func isAttached(position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isActiveHost(hostToken), hosts[hostToken]?.blockID == position.blockID else { return false }
        return (try? BlockSelectionBridge.utf16Offset(position: position, document: document)) != nil
    }

    private func applySyntheticSelection() {
        applySelection(selectionController.selection, incrementingRevision: true, project: true)
        focusSelectionEndpoint()
    }

    private func applySelection(_ newSelection: BlockEditorSelection, incrementingRevision: Bool, project: Bool) {
        selection = newSelection
        selectionController.setSelection(newSelection)
        if incrementingRevision { editorRevision &+= 1 }
        refreshSlashMenu()
        if project { projectAuthoritativeState() }
    }

    @discardableResult
    private func focusSelectionEndpoint() -> Bool {
        if let continuousHost {
            guard let window = continuousHost.textView.window else { return false }
            if window.firstResponder === continuousHost.textView { return true }
            return window.makeFirstResponder(continuousHost.textView)
        }
        guard case let .text(_, focus, _, _) = selection,
              let token = activeHostTokens[focus.blockID],
              let view = hosts[token]?.textView,
              let window = view.window else { return false }
        if window.firstResponder === view { return true }
        return window.makeFirstResponder(view)
    }

    private func isActiveHost(_ hostToken: UUID) -> Bool {
        guard let lease = hosts[hostToken] else { return false }
        return activeHostTokens[lease.blockID] == hostToken
    }

    private func consumeTerminalDuplicate(value: String, hostToken: UUID) -> Bool {
        guard let terminal = terminalComposition else { return false }
        terminalComposition = nil
        return terminal.hostToken == hostToken && terminal.value == value
    }

    private func isSelectionIncluding(blockID: BlockID) -> Bool {
        switch selection {
        case let .blocks(anchor, focus):
            let ids = document.blocks.map(\.id)
            guard let anchorIndex = ids.firstIndex(of: anchor),
                  let focusIndex = ids.firstIndex(of: focus),
                  let blockIndex = ids.firstIndex(of: blockID) else { return false }
            return min(anchorIndex, focusIndex) <= blockIndex && blockIndex <= max(anchorIndex, focusIndex)
        case let .text(anchor, focus, _, _):
            if anchor == focus { return false }
            let ids = document.blocks.map(\.id)
            guard let anchorIndex = ids.firstIndex(of: anchor.blockID),
                  let focusIndex = ids.firstIndex(of: focus.blockID),
                  let blockIndex = ids.firstIndex(of: blockID) else { return false }
            let lower = min(anchorIndex, focusIndex)
            let upper = max(anchorIndex, focusIndex)
            if lower < blockIndex && blockIndex < upper { return true }
            if anchor.blockID == focus.blockID, anchor.blockID == blockID { return anchor.graphemeOffset != focus.graphemeOffset }
            return blockIndex == lower || blockIndex == upper
        }
    }

    private static func isContinuousCaret(_ selection: BlockEditorSelection, in blockID: BlockID) -> Bool {
        guard case let .text(anchor, focus, _, _) = selection else { return false }
        return anchor == focus && anchor.blockID == blockID
    }
}

private extension BlockUndoAction {
    var undoName: String {
        switch self {
        case .enter: "换行"
        case .softBreak: "软换行"
        case .documentIngest: "导入文档"
        case .taskCompletion: "切换待办状态"
        case .backspace, .deletion: "删除"
        case .indentation: "缩进"
        case .conversion: "转换"
        case .formatting: "格式"
        case .link: "链接"
        case .cut: "剪切"
        case .paste: "粘贴"
        case .drag: "移动 Block"
        }
    }
}

@MainActor
private final class HostLease {
    let blockID: BlockID
    let token: UUID
    weak var textView: BlockEditorTextView?

    init(blockID: BlockID, token: UUID, textView: BlockEditorTextView) {
        self.blockID = blockID
        self.token = token
        self.textView = textView
    }
}

private struct Snapshot: Equatable {
    let document: BlockDocument
    let selection: BlockEditorSelection
}

@MainActor
private final class TypingUndoRecord {
    let before: Snapshot
    var after: Snapshot
    let blockID: BlockID

    init(before: Snapshot, after: Snapshot, blockID: BlockID) {
        self.before = before
        self.after = after
        self.blockID = blockID
    }
}

private struct CompositionBaseline {
    let document: BlockDocument
    let originalSelection: BlockEditorSelection
    let replacementSelection: BlockEditorSelection
    let blockID: BlockID
    let hostToken: UUID
    let token: UInt
}

private struct TerminalComposition {
    let token: UInt
    let hostToken: UUID
    let value: String?
}

private struct DismissedSlash {
    let blockID: BlockID
    let queryRange: Range<Int>
    let query: String
    let revision: UInt
}
