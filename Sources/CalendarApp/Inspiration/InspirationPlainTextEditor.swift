import AppKit
import SwiftUI

/// Plain inspiration body editor that keeps IME marked text intact when the
/// surrounding SwiftUI view refreshes (autosave status, list updates, etc.).
/// Registers its own undo manager with `EditorFocusRegistry` so Command-Z
/// cannot fall through to workspace undo while this field is focused.
struct InspirationPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    var focusRegistry: EditorFocusRegistry
    var focusGeneration: UInt = 0
    var fittedHeight: Binding<CGFloat> = .constant(0)
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            focusRegistry: focusRegistry,
            onChange: { text = $0 },
            onHeight: { fittedHeight.wrappedValue = $0 },
            onFocusChange: onFocusChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        scroll.verticalScrollElasticity = .none

        let textView = InspirationContentTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
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
        textView.setAccessibilityIdentifier("inspiration-content-editor")
        textView.setAccessibilityLabel("灵感内容")
        textView.setAccessibilityRole(.textArea)

        applyChrome(to: textView)
        textView.string = text
        applyBodyAttributes(to: textView)

        context.coordinator.textView = textView
        context.coordinator.lastEmitted = text
        textView.onRemovedFromWindow = { [weak coordinator = context.coordinator] in
            coordinator?.unregisterFocus()
        }
        textView.onFittingHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.publishHeight(height)
        }
        scroll.documentView = textView
        context.coordinator.publishHeight(InspirationContentTextView.fittingHeight(for: textView))
        context.coordinator.applyFocusIfNeeded(generation: focusGeneration)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.focusRegistry = focusRegistry
        context.coordinator.onChange = { text = $0 }
        context.coordinator.onHeight = { fittedHeight.wrappedValue = $0 }
        context.coordinator.onFocusChange = onFocusChange
        guard let textView = scroll.documentView as? InspirationContentTextView else { return }
        if textView.hasMarkedText() {
            context.coordinator.applyFocusIfNeeded(generation: focusGeneration)
            return
        }
        applyChrome(to: textView)
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            applyBodyAttributes(to: textView)
            context.coordinator.lastEmitted = text
            restoreSelection(selected, in: text, textView: textView)
        }
        context.coordinator.publishHeight(InspirationContentTextView.fittingHeight(for: textView))
        context.coordinator.applyFocusIfNeeded(generation: focusGeneration)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.unregisterFocus()
    }

    private func applyChrome(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let font = NSFont.systemFont(ofSize: 18, weight: .regular)
        let color = NSColor(textColor)
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func applyBodyAttributes(to textView: NSTextView) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttributes(
            textView.typingAttributes,
            range: NSRange(location: 0, length: storage.length)
        )
    }

    private func restoreSelection(_ selected: NSRange, in text: String, textView: NSTextView) {
        let maxLength = (text as NSString).length
        let location = min(max(selected.location, 0), maxLength)
        let length = min(max(selected.length, 0), maxLength - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let ownerID = UUID()
        var focusRegistry: EditorFocusRegistry
        var onChange: (String) -> Void
        var onHeight: (CGFloat) -> Void
        var onFocusChange: (Bool) -> Void
        weak var textView: InspirationContentTextView?
        var lastEmitted: String = ""
        private var appliedFocusGeneration: UInt = 0
        private var lastPublishedHeight: CGFloat = 0
        private var undoTokens: [NSObjectProtocol] = []

        init(
            focusRegistry: EditorFocusRegistry,
            onChange: @escaping (String) -> Void,
            onHeight: @escaping (CGFloat) -> Void,
            onFocusChange: @escaping (Bool) -> Void
        ) {
            self.focusRegistry = focusRegistry
            self.onChange = onChange
            self.onHeight = onHeight
            self.onFocusChange = onFocusChange
        }

        func textDidBeginEditing(_ notification: Notification) {
            registerFocus()
            onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            if let textView, textView.hasMarkedText() {
                textView.unmarkText()
            }
            emitCommittedText()
            unregisterFocus()
            onFocusChange(false)
        }

        func textDidChange(_ notification: Notification) {
            registerFocus()
            emitCommittedText()
            if let textView {
                publishHeight(InspirationContentTextView.fittingHeight(for: textView))
            }
        }

        func applyFocusIfNeeded(generation: UInt) {
            guard generation != appliedFocusGeneration else { return }
            appliedFocusGeneration = generation
            guard generation > 0, textView != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView, let window = textView.window else { return }
                _ = window.makeFirstResponder(textView)
                if !textView.hasMarkedText() {
                    let end = (textView.string as NSString).length
                    textView.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }

        func publishHeight(_ height: CGFloat) {
            guard abs(height - lastPublishedHeight) > 0.5 else { return }
            lastPublishedHeight = height
            onHeight(height)
        }

        func unregisterFocus() {
            unbindUndoSync()
            focusRegistry.clear(ownerID: ownerID)
        }

        private func registerFocus() {
            guard let manager = textView?.undoManager else { return }
            focusRegistry.register(manager, ownerID: ownerID)
            bindUndoSync(to: manager)
        }

        private func bindUndoSync(to manager: UndoManager) {
            unbindUndoSync()
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                .NSUndoManagerDidUndoChange,
                .NSUndoManagerDidRedoChange
            ]
            for name in names {
                undoTokens.append(center.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    let emit = {
                        MainActor.assumeIsolated {
                            self.emitCommittedText()
                        }
                    }
                    if Thread.isMainThread {
                        emit()
                    } else {
                        DispatchQueue.main.sync(execute: emit)
                    }
                })
            }
        }

        private func unbindUndoSync() {
            let center = NotificationCenter.default
            undoTokens.forEach(center.removeObserver)
            undoTokens.removeAll()
        }

        private func emitCommittedText() {
            guard let textView, !textView.hasMarkedText() else { return }
            let next = textView.string
            guard next != lastEmitted else { return }
            lastEmitted = next
            onChange(next)
        }
    }
}

final class InspirationContentTextView: NSTextView {
    let ownedUndoManager = UndoManager()
    var onRemovedFromWindow: (() -> Void)?
    var onFittingHeightChange: ((CGFloat) -> Void)?

    override var undoManager: UndoManager? { ownedUndoManager }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.fittingHeight(for: self))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            onRemovedFromWindow?()
        }
    }

    static func fittingHeight(for textView: NSTextView) -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: 18, weight: .regular)
        let minimum = ceil(font.boundingRectForFont.height + 6)
        let breathingRoom: CGFloat = 10
        let width = textView.bounds.width
        guard width > 1, let container = textView.textContainer, let layout = textView.layoutManager else {
            return minimum + breathingRoom
        }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let inset = textView.textContainerInset
        let height = ceil(used.height + inset.height * 2)
        return max(height, minimum) + breathingRoom
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
