import AppKit
import SwiftUI

// MARK: - Public WYSIWYG editor

/// 所见即所得随记。列表在编辑区显示为 `•` / `1.` / `☐`，存盘仍为 Markdown。
struct MarkdownNotesEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat = 200

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var bridge = MarkdownNotesBridge()

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("随记")
                    .font(EditorFormStyle.label)
                    .foregroundStyle(theme.secondaryText)
                Text("补充说明、清单或链接")
                    .font(EditorFormStyle.caption)
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                Spacer(minLength: 0)
            }

            toolbar

            MarkdownNotesTextView(
                text: $text,
                bridge: bridge,
                theme: theme,
                appearance: appearance
            )
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.canvas.opacity(colorScheme == .dark ? 0.35 : 0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.55), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolButton("H", help: "标题") { bridge.apply(.heading) }
            toolButton("B", help: "加粗", bold: true) { bridge.apply(.bold) }
            toolButton("I", help: "斜体", italic: true) { bridge.apply(.italic) }
            toolbarDivider
            toolButton(systemName: "checklist", help: "清单") { bridge.apply(.checklist) }
            toolButton(systemName: "list.bullet", help: "无序列表") { bridge.apply(.unorderedList) }
            toolButton(systemName: "list.number", help: "有序列表") { bridge.apply(.orderedList) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.subtleBorder.opacity(0.22))
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.separator.opacity(0.7))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func toolButton(
        _ title: String,
        help: String,
        bold: Bool = false,
        italic: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: bold ? .bold : .semibold))
                .italic(italic)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primaryText)
        .help(help)
    }

    private func toolButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primaryText)
        .help(help)
    }
}

// MARK: - Bridge (toolbar → text view). Strong handler, never silently no-op.

@MainActor
final class MarkdownNotesBridge: ObservableObject {
    /// Set by the representable every update; invoked by toolbar.
    var applyCommand: ((MarkdownNotesCommand) -> Void)?

    func apply(_ command: MarkdownNotesCommand) {
        if let applyCommand {
            applyCommand(command)
        } else {
            // Representable not mounted yet — queue until ready.
            pending = command
        }
    }

    fileprivate var pending: MarkdownNotesCommand?
}

// MARK: - NSTextView representable

private struct MarkdownNotesTextView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var bridge: MarkdownNotesBridge
    let theme: CalendarSemanticAppearance
    let appearance: CalendarAppearance

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown: text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.focusRingType = .none

        let textView = NotesNSTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = false
        textView.focusRingType = .none

        context.coordinator.textView = textView
        context.coordinator.theme = theme
        context.coordinator.appearance = appearance
        context.coordinator.loadMarkdown(text, force: true)
        context.coordinator.lastEmittedMarkdown = text

        textView.onChecklistToggle = { [weak coordinator = context.coordinator] index in
            coordinator?.toggleChecklist(at: index)
        }

        scroll.documentView = textView
        wireBridge(context.coordinator)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let metricsChanged = coordinator.theme != theme || coordinator.appearance != appearance
        coordinator.theme = theme
        coordinator.appearance = appearance
        coordinator.onMarkdownChange = { md in
            if text != md {
                text = md
            }
        }
        wireBridge(coordinator)

        coordinator.syncExternalMarkdownIfNeeded(text)
        if metricsChanged {
            coordinator.reloadPreservingSelection()
        }
        coordinator.refreshChrome()

        // Flush toolbar tap that happened before the view mounted.
        if let pending = bridge.pending {
            bridge.pending = nil
            coordinator.apply(pending)
        }
    }

    private func wireBridge(_ coordinator: Coordinator) {
        bridge.applyCommand = { [weak coordinator] command in
            coordinator?.apply(command)
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NotesNSTextView?
        var theme: CalendarSemanticAppearance = CalendarTheme.light
        var appearance: CalendarAppearance = .light
        var onMarkdownChange: ((String) -> Void)?

        var lastEmittedMarkdown: String
        private var isMutatingProgrammatically = false
        /// Last caret while this field was first responder. Toolbar buttons
        /// resign the text view, so `selectedRange()` at apply time can snap to 0.
        private var lastEditingSelection = NSRange(location: 0, length: 0)

        init(markdown: String) {
            lastEmittedMarkdown = markdown
        }

        private var metrics: NotesRichTextMetrics {
            NotesRichTextMetrics.make(theme: theme, appearance: appearance)
        }

        func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
            let m = metrics
            return [
                .font: NSFont.systemFont(ofSize: m.bodySize),
                .foregroundColor: m.textColor,
                .notesBlock: NotesBlockKind.paragraph.rawValue
            ]
        }

        func refreshChrome() {
            guard let textView else { return }
            textView.insertionPointColor = NSColor(theme.controlAccent)
            // Don't stomp typing attributes if user is mid-list typing.
            if textView.typingAttributes[.notesBlock] == nil {
                textView.typingAttributes = defaultTypingAttributes()
            }
        }

        func loadMarkdown(_ markdown: String, force: Bool = false) {
            guard let textView, let storage = textView.textStorage else { return }
            if !force, storage.string.count > 0, markdown == lastEmittedMarkdown {
                return
            }
            isMutatingProgrammatically = true
            defer { isMutatingProgrammatically = false }
            let rich = MarkdownRichTextCodec.attributedString(from: markdown, metrics: metrics)
            storage.beginEditing()
            storage.setAttributedString(rich)
            storage.endEditing()
            textView.typingAttributes = defaultTypingAttributes()
            textView.insertionPointColor = NSColor(theme.controlAccent)
        }

        func syncExternalMarkdownIfNeeded(_ external: String) {
            guard external != lastEmittedMarkdown else { return }
            guard let textView else {
                lastEmittedMarkdown = external
                return
            }
            // Never clobber while the field is focused and content differs from external
            // because of in-progress WYSIWYG (display • vs stored -).
            if textView.window?.firstResponder === textView {
                return
            }
            let selection = textView.selectedRange()
            loadMarkdown(external, force: true)
            lastEmittedMarkdown = external
            let maxLen = textView.string.utf16.count
            let loc = min(selection.location, maxLen)
            let len = min(selection.length, max(0, maxLen - loc))
            textView.setSelectedRange(NSRange(location: loc, length: len))
        }

        func reloadPreservingSelection() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let md = MarkdownRichTextCodec.markdown(from: storage)
            loadMarkdown(md, force: true)
            let maxLen = textView.string.utf16.count
            let loc = min(selection.location, maxLen)
            let len = min(selection.length, max(0, maxLen - loc))
            textView.setSelectedRange(NSRange(location: loc, length: len))
        }

        func apply(_ command: MarkdownNotesCommand) {
            guard let textView else { return }

            // Ensure we have a text storage even if empty.
            let storage = textView.textStorage ?? NSTextStorage()

            let selection = textView.window?.firstResponder === textView
                ? textView.selectedRange()
                : lastEditingSelection

            // Empty selection + bold/italic → arm next keystrokes.
            if selection.length == 0, command == .bold || command == .italic {
                var typing = textView.typingAttributes
                let base = (typing[.font] as? NSFont) ?? NSFont.systemFont(ofSize: metrics.bodySize)
                let trait: NSFontTraitMask = command == .bold ? .boldFontMask : .italicFontMask
                let traits = NSFontManager.shared.traits(of: base)
                typing[.font] = traits.contains(trait)
                    ? NSFontManager.shared.convert(base, toNotHaveTrait: trait)
                    : NSFontManager.shared.convert(base, toHaveTrait: trait)
                textView.typingAttributes = typing
                textView.window?.makeFirstResponder(textView)
                return
            }

            // For list/heading with empty selection: still apply to the current line.
            // For multi-line intent without selection, expand to all content if short notes.
            var range = selection
            if selection.length == 0,
               command == .unorderedList || command == .orderedList || command == .checklist || command == .heading {
                // Prefer current line; if document has multiple lines and caret at 0 with empty line,
                // still only current line — user can select all.
                range = selection
            }

            let source: NSAttributedString = storage.length > 0
                ? storage
                : NSAttributedString(string: "")

            let (next, newSelection) = MarkdownRichTextCodec.apply(
                command,
                to: source,
                selectedRange: range,
                metrics: metrics
            )

            isMutatingProgrammatically = true
            storage.beginEditing()
            storage.setAttributedString(next)
            storage.endEditing()
            isMutatingProgrammatically = false

            // Keep caret valid and focus the field so the user sees the change immediately.
            let maxLen = storage.length
            let loc = min(newSelection.location, maxLen)
            let len = min(newSelection.length, max(0, maxLen - loc))
            let placed = NSRange(location: loc, length: len)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(placed)
            lastEditingSelection = placed
            textView.scrollRangeToVisible(NSRange(location: loc, length: 0))

            // Typing attributes follow the line's block (so Return continues the list).
            updateTypingAttributesFromCaret()
            emitMarkdownFromStorage()
        }

        func toggleChecklist(at characterIndex: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            guard let next = MarkdownRichTextCodec.toggleChecklistChecked(
                in: storage,
                at: characterIndex,
                metrics: metrics
            ) else { return }
            let selection = textView.selectedRange()
            isMutatingProgrammatically = true
            storage.beginEditing()
            storage.setAttributedString(next)
            storage.endEditing()
            isMutatingProgrammatically = false
            let maxLen = storage.length
            let loc = min(selection.location, maxLen)
            let len = min(selection.length, max(0, maxLen - loc))
            textView.setSelectedRange(NSRange(location: loc, length: len))
            emitMarkdownFromStorage()
        }

        private func updateTypingAttributesFromCaret() {
            guard let textView, let storage = textView.textStorage else { return }
            var typing = defaultTypingAttributes()
            if storage.length > 0 {
                let loc = min(max(0, textView.selectedRange().location), storage.length)
                let idx = min(max(0, loc > 0 ? loc - 1 : 0), storage.length - 1)
                let attrs = storage.attributes(at: idx, effectiveRange: nil)
                if let font = attrs[.font] { typing[.font] = font }
                if let block = attrs[.notesBlock] { typing[.notesBlock] = block }
                if let checked = attrs[.notesChecked] { typing[.notesChecked] = checked }
                if let para = attrs[.paragraphStyle] { typing[.paragraphStyle] = para }
                // Continue list markers on Return: prefix is inserted by textView insertText override
                // when notesBlock is bullet/ordered/checklist.
            }
            textView.typingAttributes = typing
            textView.currentBlockKind = {
                if let raw = typing[.notesBlock] as? String {
                    return NotesBlockKind(rawValue: raw) ?? .paragraph
                }
                return .paragraph
            }()
        }

        private func emitMarkdownFromStorage() {
            guard let storage = textView?.textStorage else { return }
            let md = MarkdownRichTextCodec.markdown(from: storage)
            guard md != lastEmittedMarkdown else { return }
            lastEmittedMarkdown = md
            onMarkdownChange?(md)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isMutatingProgrammatically, let textView else { return }
            if textView.hasMarkedText() { return }

            // Do NOT auto-convert typed "1. " / "- " into list commands.
            // That raced with toggle semantics and wiped lines (body became empty).
            // Lists are applied only via the toolbar (or Return continuation).

            ensureBlockAttributesOnEditedText()
            updateTypingAttributesFromCaret()
            emitMarkdownFromStorage()
        }

        private func ensureBlockAttributesOnEditedText() {
            guard let storage = textView?.textStorage, storage.length > 0 else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.notesBlock, in: full, options: []) { value, range, _ in
                if value == nil {
                    storage.addAttribute(
                        .notesBlock,
                        value: NotesBlockKind.paragraph.rawValue,
                        range: range
                    )
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView, textView.window?.firstResponder === textView {
                lastEditingSelection = textView.selectedRange()
            }
            updateTypingAttributesFromCaret()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // On Return inside a list line, insert newline + fresh list marker.
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return insertListContinuationIfNeeded(in: textView)
            }
            return false
        }

        private func insertListContinuationIfNeeded(in textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage, storage.length > 0 else { return false }
            let sel = textView.selectedRange()
            let idx = min(max(0, sel.location > 0 ? sel.location - 1 : 0), storage.length - 1)
            let raw = storage.attribute(.notesBlock, at: idx, effectiveRange: nil) as? String
            let kind = NotesBlockKind(rawValue: raw ?? "") ?? .paragraph
            guard kind == .bullet || kind == .ordered || kind == .checklist else { return false }

            let marker: String
            switch kind {
            case .bullet: marker = "• "
            case .checklist: marker = "☐ "
            case .ordered:
                // Count ordered lines up to current, next index + 1
                let ns = storage.string as NSString
                let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
                var count = 0
                var loc = 0
                while loc <= lineRange.location && loc < ns.length {
                    let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
                    let k = storage.attribute(
                        .notesBlock,
                        at: lr.location,
                        effectiveRange: nil
                    ) as? String
                    if k == NotesBlockKind.ordered.rawValue { count += 1 }
                    loc = NSMaxRange(lr)
                    if lr.length == 0 { break }
                }
                marker = "\(count + 1). "
            default:
                return false
            }

            let attrs = storage.attributes(at: idx, effectiveRange: nil)
            let insertion = NSAttributedString(string: "\n" + marker, attributes: attrs)
            if textView.shouldChangeText(in: sel, replacementString: "\n" + marker) {
                isMutatingProgrammatically = true
                storage.replaceCharacters(in: sel, with: insertion)
                isMutatingProgrammatically = false
                textView.didChangeText()
                var newLoc = sel.location + (insertion.string as NSString).length
                // Renumber ordered lists after insert via round-trip (does not toggle type off).
                if kind == .ordered {
                    let md = MarkdownRichTextCodec.markdown(from: storage)
                    loadMarkdown(md, force: true)
                    newLoc = min(newLoc, storage.length)
                }
                textView.setSelectedRange(NSRange(location: newLoc, length: 0))
                emitMarkdownFromStorage()
                updateTypingAttributesFromCaret()
                return true
            }
            return false
        }
    }
}

// MARK: - NSTextView subclass

private final class NotesNSTextView: NSTextView {
    var onChecklistToggle: ((Int) -> Void)?
    var currentBlockKind: NotesBlockKind = .paragraph

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let layoutManager, let textContainer, let storage = textStorage,
           storage.length > 0 {
            let point = convert(event.locationInWindow, from: nil)
            var frac: CGFloat = 0
            let index = layoutManager.characterIndex(
                for: point,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: &frac
            )
            let ns = storage.string as NSString
            let safeIndex = min(max(0, index), ns.length - 1)
            let line = ns.lineRange(for: NSRange(location: safeIndex, length: 0))
            var body = line
            if body.length > 0 {
                let last = ns.character(at: NSMaxRange(body) - 1)
                if last == 10 || last == 13 { body.length -= 1 }
            }
            if body.length > 0 {
                let lineText = ns.substring(with: body)
                let isChecklistLine = lineText.hasPrefix("☐") || lineText.hasPrefix("☑")
                    || (storage.attribute(.notesBlock, at: body.location, effectiveRange: nil) as? String)
                    == NotesBlockKind.checklist.rawValue
                // Generous hit area: first 3 UTF-16 units of the line (glyph + space + a bit).
                if isChecklistLine, safeIndex < body.location + 3 {
                    onChecklistToggle?(safeIndex)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let plain = NSPasteboard.general.string(forType: .string) {
            let attrs = typingAttributes
            let piece = NSAttributedString(string: plain, attributes: attrs)
            if shouldChangeText(in: selectedRange(), replacementString: plain) {
                textStorage?.replaceCharacters(in: selectedRange(), with: piece)
                didChangeText()
            }
            return
        }
        super.pasteAsPlainText(sender)
    }
}

// MARK: - Detail preview

struct MarkdownNotesPreview: View {
    let markdown: String
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else {
            Text(previewAttributed)
                .font(EditorFormStyle.body)
                .foregroundStyle(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(12)
        }
    }

    private var previewAttributed: AttributedString {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return attributed
        }
        return AttributedString(markdown)
    }
}
