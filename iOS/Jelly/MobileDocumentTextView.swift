import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WorkspaceDomain

/// One native text surface owns the continuous selection, autocorrection and
/// IME. All committed mutations are interpreted by the desktop's block reducer.
struct MobileDocumentTextView: UIViewRepresentable {
    let session: MobileNoteSession
    let editable: Bool
    /// Asks the host to pick a note; the callback inserts a link to it.
    var onRequestNoteLink: ((@escaping (NoteID, String) -> Void) -> Void)?
    var onOpenNote: (NoteID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        let view = MobileDocumentUITextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .init(top: 8, left: 48, bottom: 12, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "笔记正文，支持连续选择与编辑"
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.command = { [weak coordinator = context.coordinator] in coordinator?.send($0) }
        view.pasteAction = { [weak coordinator = context.coordinator] in coordinator?.paste() }
        view.compositionChanged = { [weak coordinator = context.coordinator] composing in
            coordinator?.parent.session.isComposingText = composing
        }
        view.appearanceChanged = { [weak coordinator = context.coordinator] in coordinator?.render() }
        view.toggleTask = { [weak coordinator = context.coordinator] blockID in
            guard let coordinator, let block = coordinator.parent.session.draft.document.blocks.first(where: { $0.id == blockID }) else { return }
            coordinator.send(.setTaskCompletion(blockID: blockID, completedAt: block.taskState?.completedAt == nil ? Date() : nil))
        }
        context.coordinator.installToolbar()
        context.coordinator.render()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable
        context.coordinator.render()
        (view as? MobileDocumentUITextView)?.refreshMarkerAccess()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // UITextView can report a zero content width when empty. Retain the
        // row's proposed width so a new note still has an editable hit area.
        return CGSize(width: width, height: measured.height)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileDocumentTextView
        weak var view: MobileDocumentUITextView?
        var map: MobileDocumentTextMap
        var renderedDocument: BlockDocument
        var applying = false
        var lastSelectionID: UUID?
        var lastClipboardID: UUID?
        var slashSelection: BlockEditorSelection?
        var slashSignature: String?
        var formatItem: UIBarButtonItem?
        var renderedScheme: ColorScheme?
        var renderedContentSize: UIContentSizeCategory?
        let marksKey = NSAttributedString.Key("JellyInlineMarks")
        static let clipboardType = "app.jelly.block-selection"

        init(parent: MobileDocumentTextView) {
            self.parent = parent
            map = .init(parent.session.draft.document)
            renderedDocument = parent.session.draft.document
        }

        func installToolbar() {
            guard let view else { return }
            let format = UIBarButtonItem(title: "块类型", image: nil, primaryAction: nil, menu: blockMenu(slash: false))
            formatItem = format
            let toolbar = UIToolbar()
            toolbar.items = [
                format,
                UIBarButtonItem(title: "粗", style: .plain, target: self, action: #selector(bold)),
                UIBarButtonItem(title: "斜", style: .plain, target: self, action: #selector(italic)),
                UIBarButtonItem(title: "代码", style: .plain, target: self, action: #selector(code)),
                UIBarButtonItem(title: "链接", style: .plain, target: self, action: #selector(link)),
                UIBarButtonItem(title: "笔记", style: .plain, target: self, action: #selector(noteLink)),
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
            ]
            toolbar.sizeToFit()
            view.inputAccessoryView = toolbar
        }

        private func blockMenu(slash: Bool) -> UIMenu {
            let choices: [(String, BlockKind)] = [("正文", .paragraph), ("一级标题", .heading1), ("二级标题", .heading2),
                ("三级标题", .heading3), ("无序列表", .bullet), ("有序列表", .ordered), ("待办", .task),
                ("引用", .quote), ("代码块", .code), ("分割线", .divider)]
            return UIMenu(title: slash ? "将 / 转成内容块" : "转换选中内容块", children: choices.map { title, kind in
                UIAction(title: title) { [weak self] _ in
                    guard let self else { return }
                    let command: BlockInputCommand = kind == .divider && !slash ? .insertDivider : (slash ? .applySlashConversion(kind) : .convert(kind))
                    self.send(command, selection: slash ? self.slashSelection : nil)
                }
            } + [UIAction(title: "增加缩进") { [weak self] _ in self?.send(.indent) },
                 UIAction(title: "减少缩进") { [weak self] _ in self?.send(.outdent) }])
        }

        func render() {
            guard let view, !applying, !view.updatingMarkedText, view.markedTextRange == nil else { return }
            applying = true
            defer { applying = false }
            let next = parent.session.draft.document
            let nextMap = MobileDocumentTextMap(next)
            let oldSelection = map.selection(in: view.selectedRange, attributes: typingAttributes())
            let appearanceChanged = renderedScheme != parent.colorScheme || renderedContentSize != view.traitCollection.preferredContentSizeCategory
            if renderedDocument != next || view.attributedText.length == 0 || view.text != nextMap.text || appearanceChanged {
                renderedScheme = parent.colorScheme
                renderedContentSize = view.traitCollection.preferredContentSizeCategory
                view.attributedText = attributed(nextMap)
                map = nextMap
                renderedDocument = next
                view.documentMap = nextMap
                if let oldSelection, let range = map.range(of: oldSelection) { view.selectedRange = range }
                else { view.selectedRange = .init(location: min(view.selectedRange.location, map.text.utf16.count), length: 0) }
            }
            if let request = parent.session.selectionRequest, request.id != lastSelectionID {
                lastSelectionID = request.id
                if let range = map.range(of: request.selection) { view.selectedRange = range }
                if case let .text(_, _, _, attributes) = request.selection {
                    view.typingAttributes = spanAttributes(.init(text: "", marks: attributes.marks, linkURL: attributes.linkURL), kind: activeKind())
                }
            }
            if let request = parent.session.clipboardRequest, request.id != lastClipboardID {
                lastClipboardID = request.id
                writeClipboard(request.payload)
            }
            if view.text.isEmpty { view.typingAttributes = spanAttributes(.init(text: ""), kind: activeKind()) }
            parent.session.selection = map.selection(in: view.selectedRange, attributes: typingAttributes())
            refreshSlash()
            view.invalidateIntrinsicContentSize()
        }

        private func activeKind() -> BlockKind {
            guard let view, let position = map.position(at: view.selectedRange.location) else { return .paragraph }
            return map.entries.first { $0.block.id == position.blockID }?.block.kind ?? .paragraph
        }

        private func spanAttributes(_ span: InlineSpan, kind: BlockKind) -> [NSAttributedString.Key: Any] {
            let size: CGFloat = kind == .heading1 ? 28 : kind == .heading2 ? 23 : kind == .heading3 ? 20 : 17
            var font = kind == .code || span.marks.contains(.code) ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular) : UIFont.systemFont(ofSize: size)
            var traits = font.fontDescriptor.symbolicTraits
            if span.marks.contains(.bold) || [.heading1, .heading2, .heading3].contains(kind) { traits.insert(.traitBold) }
            if span.marks.contains(.italic) || kind == .quote { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: size) }
            var attributes: [NSAttributedString.Key: Any] = [.font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font),
                .foregroundColor: UIColor(CalendarTheme.appearance(for: parent.colorScheme).primaryText),
                marksKey: span.marks.map(\.rawValue).sorted().joined(separator: ",")]
            if let url = span.linkURL { attributes[.link] = url }
            if span.marks.contains(.code) || kind == .code { attributes[.backgroundColor] = UIColor.secondarySystemFill }
            return attributes
        }

        private func attributed(_ map: MobileDocumentTextMap) -> NSAttributedString {
            let output = NSMutableAttributedString(string: "")
            for (index, entry) in map.entries.enumerated() {
                if index > 0 { output.append(NSAttributedString(string: "\n", attributes: spanAttributes(.init(text: ""), kind: .paragraph))) }
                let start = output.length
                if entry.block.kind == .divider {
                    let attachment = NSTextAttachment()
                    attachment.image = UIImage(systemName: "minus")?.withTintColor(.secondaryLabel)
                    attachment.bounds = CGRect(x: 0, y: -2, width: 100, height: 16)
                    output.append(NSAttributedString(attachment: attachment))
                } else {
                    for span in entry.block.inlineContent.spans {
                        output.append(NSAttributedString(string: span.text, attributes: spanAttributes(span, kind: entry.block.kind)))
                    }
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 10
                if entry.block.kind == .task { paragraph.minimumLineHeight = 34 }
                paragraph.headIndent = CGFloat(entry.block.indentLevel) * 20
                paragraph.firstLineHeadIndent = paragraph.headIndent
                if entry.block.kind == .quote { paragraph.headIndent += 16; paragraph.firstLineHeadIndent += 16 }
                if output.length > start { output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: output.length - start)) }
            }
            return output
        }

        private func typingAttributes() -> BlockTypingAttributes {
            let names = view?.typingAttributes[marksKey] as? String ?? ""
            return .init(marks: Set(names.split(separator: ",").compactMap { InlineMark(rawValue: String($0)) }),
                         linkURL: view?.typingAttributes[.link] as? URL)
        }

        func send(_ command: BlockInputCommand, range: NSRange? = nil, selection: BlockEditorSelection? = nil) {
            guard let view, !view.updatingMarkedText, view.markedTextRange == nil else { return }
            publishCommittedText()
            guard let selection = selection ?? map.selection(in: range ?? view.selectedRange, attributes: typingAttributes()) else { return }
            _ = parent.session.dispatch(selection: selection, command: command)
            render()
        }

        func textViewDidChange(_ textView: UITextView) { publishCommittedText() }
        func textViewDidEndEditing(_ textView: UITextView) { publishCommittedText() }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying else { return }
            if textView.markedTextRange != nil { parent.session.isComposingText = true; return }
            // Some input methods end composition through selection callbacks.
            if parent.session.isComposingText { publishCommittedText() }
            parent.session.selection = map.selection(in: textView.selectedRange, attributes: typingAttributes())
            refreshSlash()
        }

        private func publishCommittedText() {
            guard let view, !applying, !view.updatingMarkedText else { return }
            parent.session.isComposingText = view.markedTextRange != nil
            guard view.markedTextRange == nil, let delta = map.replacement(to: view.text),
                  let selection = map.selection(in: delta.range, attributes: typingAttributes()) else { return }
            let command: BlockInputCommand = delta.text.isEmpty ? .deleteSelection :
                (delta.text.contains("\n") || delta.text.contains("\r") ? .replaceSelection(.plainText(delta.text)) : .insertText(delta.text))
            _ = parent.session.dispatch(selection: selection, command: command)
            render()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applying, view?.updatingMarkedText != true, textView.markedTextRange == nil else { return true }
            if text == "\n" { send(.enter, range: range); return false }
            if text == "\t" { send(.indent, range: range); return false }
            if text == " " { send(.insertTextApplyingMarkdownShortcut(text), range: range); return false }
            if text.contains("\n") || text.contains("\r") { send(.replaceSelection(.plainText(text)), range: range); return false }
            // Ordinary input stays native until UIKit identifies the committed
            // text. Intercepting each character here would break marked text.
            return true
        }

        private func refreshSlash() {
            guard let view, view.markedTextRange == nil,
                  let selection = map.selection(in: view.selectedRange, attributes: typingAttributes()),
                  case let .text(anchor, focus, _, _) = selection, anchor == focus,
                  let entry = map.entries.first(where: { $0.block.id == anchor.blockID }), entry.block.kind == .paragraph else {
                slashSelection = nil
                if slashSignature != nil { slashSignature = nil; formatItem?.title = "块类型"; formatItem?.menu = blockMenu(slash: false) }
                return
            }
            let prefix = String(entry.text.prefix(anchor.graphemeOffset))
            guard prefix.hasPrefix("/"), !prefix.contains(where: \.isNewline) else {
                slashSelection = nil
                if slashSignature != nil { slashSignature = nil; formatItem?.title = "块类型"; formatItem?.menu = blockMenu(slash: false) }
                return
            }
            slashSelection = selection
            if slashSignature != prefix { slashSignature = prefix; formatItem?.title = "/ 转换"; formatItem?.menu = blockMenu(slash: true) }
        }

        @objc func bold() { send(.toggleInlineMark(.bold)) }
        @objc func italic() { send(.toggleInlineMark(.italic)) }
        @objc func code() { send(.toggleInlineMark(.code)) }
        @objc func done() { view?.endEditing(true) }
        @objc func noteLink() {
            guard let view, view.markedTextRange == nil, let request = parent.onRequestNoteLink,
                  let selection = map.selection(in: view.selectedRange, attributes: typingAttributes()) else { return }
            request { [weak self] id, title in
                let content = InlineContent(spans: [
                    InlineSpan(text: title, linkURL: NoteLinkURL.url(for: id)),
                    InlineSpan(text: " ")
                ])
                self?.send(.replaceSelection(.inlineContent(content, fallbackPlainText: title + " ")), selection: selection)
            }
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content, let id = NoteLinkURL.noteID(from: url) else { return defaultAction }
            return UIAction(title: "打开笔记") { [weak self] _ in self?.parent.onOpenNote(id) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case let .link(url) = textItem.content, let id = NoteLinkURL.noteID(from: url) else { return .init(menu: defaultMenu) }
            let open = UIAction(title: "打开笔记", image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.parent.onOpenNote(id) }
            return .init(menu: UIMenu(children: [open]))
        }

        @objc func link() {
            guard let view, view.markedTextRange == nil,
                  let selection = map.selection(in: view.selectedRange, attributes: typingAttributes()) else { return }
            let alert = UIAlertController(title: "文字链接", message: "留空可移除链接", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "https://"; $0.keyboardType = .URL; $0.autocapitalizationType = .none }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "应用", style: .default) { [weak self, weak alert] _ in
                let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if raw.isEmpty { self?.send(.setLink(nil), selection: selection) }
                else if let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { self?.send(.setLink(url), selection: selection) }
            })
            var presenter = view.window?.rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            presenter?.present(alert, animated: true)
        }

        func writeClipboard(_ payload: BlockClipboardPayload) {
            let blocks = payload.richBlocks.map { DocumentBlock(id: BlockID(), kind: $0.kind, inlineContent: $0.inlineContent,
                taskState: $0.kind == .task ? .init(completedAt: nil, completionDescription: $0.completionDescription) : nil,
                indentLevel: $0.indentLevel, codeInfoString: $0.codeInfoString) }
            let value = MobileBlockClipboard(inline: payload.inlineContent, blocks: blocks)
            var item: [String: Any] = [UTType.utf8PlainText.identifier: payload.plainText]
            if let data = try? JSONEncoder().encode(value) { item[Self.clipboardType] = data }
            UIPasteboard.general.setItems([item])
        }

        func paste() {
            let pasteboard = UIPasteboard.general
            if let data = pasteboard.data(forPasteboardType: Self.clipboardType),
               let value = try? JSONDecoder().decode(MobileBlockClipboard.self, from: data) {
                if let inline = value.inline { send(.replaceSelection(.inlineContent(inline, fallbackPlainText: pasteboard.string ?? ""))) }
                else { send(.replaceSelection(.richText(blocks: value.blocks.map { .init(kind: $0.kind, inlineContent: $0.inlineContent,
                    indentLevel: $0.indentLevel, codeInfoString: $0.codeInfoString, completionDescription: $0.taskState?.completionDescription) }, fallbackPlainText: pasteboard.string ?? ""))) }
            } else if let data = pasteboard.data(forPasteboardType: UTType.html.identifier), let html = String(data: data, encoding: .utf8),
                      let imported = try? BlockHTMLCodec.importHTML(html, checkedTaskCompletedAt: Date()) {
                send(.replaceSelection(.richText(blocks: imported.document.blocks.map { .init(kind: $0.kind, inlineContent: $0.inlineContent,
                    indentLevel: $0.indentLevel, codeInfoString: $0.codeInfoString, completionDescription: $0.taskState?.completionDescription) }, fallbackPlainText: pasteboard.string ?? "")))
            } else if let text = pasteboard.string { send(.replaceSelection(.plainText(text))) }
        }
    }
}

private struct MobileBlockClipboard: Codable {
    let inline: InlineContent?
    let blocks: [DocumentBlock]
}

@MainActor final class MobileDocumentUITextView: UITextView {
    var command: ((BlockInputCommand) -> Void)?
    var pasteAction: (() -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    var appearanceChanged: (() -> Void)?
    var toggleTask: ((BlockID) -> Void)?
    var updatingMarkedText = false
    var documentMap: MobileDocumentTextMap? { didSet { rebuildMarkers() } }
    private var markers: [(UIView, MobileDocumentTextMap.Entry)] = []

    func refreshMarkerAccess() {
        for (marker, _) in markers { (marker as? UIButton)?.isEnabled = isEditable }
    }

    private func rebuildMarkers() {
        markers.forEach { $0.0.removeFromSuperview() }
        markers.removeAll()
        var orderedCounters: [Int: Int] = [:]
        for entry in documentMap?.entries ?? [] {
            let block = entry.block
            let marker: UIView
            if block.kind == .task {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: block.taskState?.completedAt == nil ? "circle" : "checkmark.circle.fill"), for: .normal)
                button.accessibilityLabel = (block.taskState?.completedAt == nil ? "完成待办：" : "重新打开待办：") + entry.text
                button.isEnabled = isEditable
                button.addAction(UIAction { [weak self] _ in self?.toggleTask?(block.id) }, for: .touchUpInside)
                marker = button
            } else if block.kind == .bullet || block.kind == .ordered {
                let label = UILabel()
                label.textAlignment = .right
                label.font = UIFont.preferredFont(forTextStyle: .body)
                label.textColor = .secondaryLabel
                if block.kind == .ordered {
                    orderedCounters[block.indentLevel, default: 0] += 1
                    orderedCounters = orderedCounters.filter { $0.key <= block.indentLevel }
                    label.text = "\(orderedCounters[block.indentLevel] ?? 1)."
                } else { label.text = "•"; orderedCounters.removeValue(forKey: block.indentLevel) }
                marker = label
            } else { orderedCounters.removeAll(); continue }
            addSubview(marker)
            markers.append((marker, entry))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutManager.ensureLayout(for: textContainer)
        for (marker, entry) in markers {
            let rect: CGRect
            if entry.range.location < textStorage.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: entry.range.location)
                rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { rect = layoutManager.extraLineFragmentRect }
            marker.frame = CGRect(x: textContainerInset.left + CGFloat(entry.block.indentLevel) * 20 - 46,
                                  y: textContainerInset.top + rect.minY - 5, width: 44, height: max(44, rect.height + 10))
        }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        appearanceChanged?()
    }
    override func copy(_ sender: Any?) { command?(.copySelection) }
    override func cut(_ sender: Any?) { command?(.cutSelection) }
    override func paste(_ sender: Any?) { pasteAction?() }
    override func deleteBackward() {
        if markedTextRange == nil { command?(.backspace) }
        else { super.deleteBackward() }
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        updatingMarkedText = true
        compositionChanged?(true)
        super.setMarkedText(markedText, selectedRange: selectedRange)
        updatingMarkedText = false
        compositionChanged?(markedTextRange != nil)
        if markedTextRange == nil { delegate?.textViewDidChange?(self) }
    }
    override func unmarkText() {
        updatingMarkedText = true
        super.unmarkText()
        updatingMarkedText = false
        compositionChanged?(markedTextRange != nil)
        delegate?.textViewDidChange?(self)
    }
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(softBreak)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent))
        ]
    }
    @objc private func softBreak() { command?(.softBreak) }
    @objc private func outdent() { command?(.outdent) }
}

/// Titles and raw inspiration remain plain text, but use the same committed-
/// input rule. SwiftUI bindings never receive provisional IME candidates.
struct MobileCommittedPlainTextView: UIViewRepresentable {
    @Binding var text: String
    var textStyle: UIFont.TextStyle = .body
    var editable = true
    var accessibilityName: String
    var onCompositionChange: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let view = MobilePlainUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .init(top: 5, left: 0, bottom: 5, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onCompositionChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onCompositionChange($0) }
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        uiView.isEditable = editable
        uiView.accessibilityLabel = accessibilityName
        guard uiView.markedTextRange == nil, (uiView as? MobilePlainUITextView)?.updatingMarkedText != true else { return }
        uiView.font = UIFont.preferredFont(forTextStyle: textStyle)
        uiView.textColor = UIColor(CalendarTheme.appearance(for: colorScheme).primaryText)
        if uiView.text != text {
            let selection = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = NSRange(location: min(selection.location, text.utf16.count), length: 0)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // UITextView can report a zero content width when empty. Retain the
        // row's proposed width so a new note still has an editable hit area.
        return CGSize(width: width, height: measured.height)
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileCommittedPlainTextView
        init(parent: MobileCommittedPlainTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { publish(textView) }
        func textViewDidEndEditing(_ textView: UITextView) { publish(textView) }
        func textViewDidChangeSelection(_ textView: UITextView) { publish(textView) }
        private func publish(_ view: UITextView) {
            guard (view as? MobilePlainUITextView)?.updatingMarkedText != true else { return }
            let composing = view.markedTextRange != nil
            parent.onCompositionChange(composing)
            guard !composing else { return }
            if parent.text != view.text { parent.text = view.text }
            view.invalidateIntrinsicContentSize()
        }
    }
}

@MainActor private final class MobilePlainUITextView: UITextView {
    var updatingMarkedText = false
    var onCompositionChange: ((Bool) -> Void)?
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        updatingMarkedText = true
        onCompositionChange?(true)
        super.setMarkedText(markedText, selectedRange: selectedRange)
        updatingMarkedText = false
        onCompositionChange?(markedTextRange != nil)
        if markedTextRange == nil { delegate?.textViewDidChange?(self) }
    }
    override func unmarkText() {
        updatingMarkedText = true
        super.unmarkText()
        updatingMarkedText = false
        onCompositionChange?(markedTextRange != nil)
        delegate?.textViewDidChange?(self)
    }
}
