import AppKit
import SwiftUI
import WorkspaceDomain

enum BlockFormattingAction: CaseIterable, Equatable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bold
    case italic
    case inlineCode
    case bullet
    case ordered
    case task
    case quote
    case divider
    case link
    case noteLink

    var title: String {
        switch self {
        case .paragraph: "正文"
        case .heading1: "H1"
        case .heading2: "H2"
        case .heading3: "H3"
        case .bold: "B"
        case .italic: "I"
        case .inlineCode: "</>"
        case .bullet: "•"
        case .ordered: "1."
        case .task: "☐"
        case .quote: "❝"
        case .divider: "—"
        case .link: "链接"
        case .noteLink: "[[笔记]]"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .paragraph: "block-format-paragraph"
        case .heading1: "block-format-heading-1"
        case .heading2: "block-format-heading-2"
        case .heading3: "block-format-heading-3"
        case .bold: "block-format-bold"
        case .italic: "block-format-italic"
        case .inlineCode: "block-format-code"
        case .bullet: "block-format-bullet"
        case .ordered: "block-format-ordered"
        case .task: "block-format-task"
        case .quote: "block-format-quote"
        case .divider: "block-format-divider"
        case .link: "block-format-link"
        case .noteLink: "block-format-note-link"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .paragraph: "设为正文"
        case .heading1: "设为一级标题"
        case .heading2: "设为二级标题"
        case .heading3: "设为三级标题"
        case .bold: "切换粗体"
        case .italic: "切换斜体"
        case .inlineCode: "切换行内代码"
        case .bullet: "设为无序列表"
        case .ordered: "设为有序列表"
        case .task: "设为待办"
        case .quote: "设为引用"
        case .divider: "插入分隔线"
        case .link: "添加或移除链接"
        case .noteLink: "链接到另一篇笔记"
        }
    }

    var command: BlockInputCommand? {
        switch self {
        case .paragraph: .convert(.paragraph)
        case .heading1: .convert(.heading1)
        case .heading2: .convert(.heading2)
        case .heading3: .convert(.heading3)
        case .bold: .toggleInlineMark(.bold)
        case .italic: .toggleInlineMark(.italic)
        case .inlineCode: .toggleInlineMark(.code)
        case .bullet: .convert(.bullet)
        case .ordered: .convert(.ordered)
        case .task: .convert(.task)
        case .quote: .convert(.quote)
        case .divider: .insertDivider
        case .link, .noteLink: nil
        }
    }
}

struct BlockFormattingBar: View {
    let session: BlockEditorSession?
    let requestLinkURL: () -> URL?
    @State private var isExpanded = true
    @Environment(\.colorScheme) private var colorScheme

    init(
        session: BlockEditorSession?,
        requestLinkURL: @escaping () -> URL? = { BlockLinkPrompt.requestURL() }
    ) {
        self.session = session
        self.requestLinkURL = requestLinkURL
    }

    var body: some View {
        let appearance = CalendarTheme.appearance(for: colorScheme)
        HStack(spacing: 8) {
            BlockFormattingButtonRepresentable(
                title: isExpanded ? "‹" : "›",
                identifier: "block-format-toggle",
                accessibilityLabel: isExpanded ? "收起格式栏" : "展开格式栏",
                prepareAction: { session?.prepareAuxiliaryControlAction() },
                action: toggleExpanded
            )
            .frame(width: 30, height: 28)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    if let session {
                        ObservedFormattingActions(
                            session: session,
                            requestLinkURL: requestLinkURL
                        )
                    } else {
                        DisabledFormattingActions()
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("笔记格式")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(appearance.elevatedSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(appearance.separator.opacity(0.7)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("固定格式栏")
    }

    private func toggleExpanded() {
        guard let session else {
            isExpanded.toggle()
            return
        }
        session.performAuxiliaryControlAction { isExpanded.toggle() }
    }

}

private struct ObservedFormattingActions: View {
    @ObservedObject var session: BlockEditorSession
    let requestLinkURL: () -> URL?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(BlockFormattingAction.allCases.enumerated()), id: \.element.accessibilityIdentifier) { index, action in
                if [4, 7, 12].contains(index) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }
                BlockFormattingButtonRepresentable(
                    title: action.title,
                    identifier: action.accessibilityIdentifier,
                    accessibilityLabel: action.accessibilityLabel,
                    isActive: isActive(action),
                    prepareAction: { session.prepareAuxiliaryControlAction() },
                    action: { perform(action) }
                )
                .frame(minWidth: action == .paragraph || action == .link || action == .noteLink ? 46 : 30, minHeight: 28)
            }
        }
    }

    private func isActive(_ action: BlockFormattingAction) -> Bool {
        switch action {
        case .paragraph: session.focusedBlockKind == .paragraph
        case .heading1: session.focusedBlockKind == .heading1
        case .heading2: session.focusedBlockKind == .heading2
        case .heading3: session.focusedBlockKind == .heading3
        case .bold: session.currentTypingAttributes.marks.contains(.bold)
        case .italic: session.currentTypingAttributes.marks.contains(.italic)
        case .inlineCode: session.currentTypingAttributes.marks.contains(.code)
        case .bullet: session.focusedBlockKind == .bullet
        case .ordered: session.focusedBlockKind == .ordered
        case .task: session.focusedBlockKind == .task
        case .quote: session.focusedBlockKind == .quote
        case .divider: session.focusedBlockKind == .divider
        case .link: session.selectionContainsLink || session.currentTypingAttributes.linkURL != nil
        case .noteLink: session.noteLinkMenuState != nil
        }
    }

    private func perform(_ action: BlockFormattingAction) {
        session.performAuxiliaryControlAction {
            if let command = action.command {
                _ = session.dispatchTextCommand(command)
            } else if action == .noteLink {
                session.beginNoteLink()
            } else {
                toggleLink()
            }
        }
    }

    private func toggleLink() {
        if session.selectionContainsLink || session.currentTypingAttributes.linkURL != nil {
            _ = session.dispatchTextCommand(.setLink(nil))
            return
        }
        if let clipboardValue = NSPasteboard.general.string(forType: .string),
           let clipboardURL = URL(string: clipboardValue),
           BlockURLValidator.isValid(clipboardURL) {
            _ = session.dispatchTextCommand(.setLink(clipboardURL))
            return
        }
        guard let url = requestLinkURL(), BlockURLValidator.isValid(url) else { return }
        _ = session.dispatchTextCommand(.setLink(url))
    }
}

private struct DisabledFormattingActions: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(BlockFormattingAction.allCases, id: \.accessibilityIdentifier) { action in
                BlockFormattingButtonRepresentable(
                    title: action.title,
                    identifier: action.accessibilityIdentifier,
                    accessibilityLabel: action.accessibilityLabel,
                    isActive: false,
                    prepareAction: {},
                    action: {}
                )
                .frame(minWidth: action == .paragraph || action == .link || action == .noteLink ? 46 : 30, minHeight: 28)
                .disabled(true)
            }
        }
    }
}

struct BlockFormattingButtonRepresentable: NSViewRepresentable {
    let title: String
    let identifier: String
    let accessibilityLabel: String
    var isActive = false
    let prepareAction: () -> Void
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> SelectionPreservingFormattingButton {
        let button = SelectionPreservingFormattingButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.prepareAction = prepareAction
        button.bezelStyle = .recessed
        button.controlSize = .small
        configure(button)
        return button
    }

    func updateNSView(_ button: SelectionPreservingFormattingButton, context: Context) {
        button.title = title
        button.prepareAction = prepareAction
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NSButton) {
        button.toolTip = accessibilityLabel
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.state = isActive ? .on : .off
        button.setAccessibilityValue(isActive ? "已开启" : "未开启")
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() { action() }
    }
}

@MainActor
final class SelectionPreservingFormattingButton: NSButton {
    var prepareAction: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        prepareAction()
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        prepareAction()
        return super.accessibilityPerformPress()
    }
}

@MainActor
enum BlockLinkPrompt {
    static func requestURL() -> URL? {
        let field = NSTextField(string: "https://")
        field.frame = .init(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "添加链接"
        alert.informativeText = "输入所选文本要打开的完整网址。"
        alert.accessoryView = field
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return URL(string: field.stringValue)
    }
}
