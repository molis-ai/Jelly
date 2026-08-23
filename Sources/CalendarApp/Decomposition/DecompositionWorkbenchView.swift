import AppKit
import SwiftUI

final class DecompositionNSButton: NSButton {
    var intendedEnabled = true

    override var acceptsFirstResponder: Bool { intendedEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { intendedEnabled && !isHiddenOrHasHiddenAncestor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isEnabled = intendedEnabled
        cell?.isEnabled = intendedEnabled
        refusesFirstResponder = !intendedEnabled
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        if event.keyCode == 49 {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }
}

final class DecompositionIdentifiedNSTextField: NSTextField {
    var requestsInitialFocus = false

    override var acceptsFirstResponder: Bool { isEditable && isEnabled }
    override var canBecomeKeyView: Bool { isEditable && isEnabled && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        if !isEditable || !isEnabled || refusesFirstResponder {
            return false
        }
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attemptInitialFocusIfNeeded()
    }

    func attemptInitialFocusIfNeeded() {
        let shouldRequestFocus = requestsInitialFocus || accessibilityIdentifier() == "decomposition-answer"
        guard shouldRequestFocus, let window else { return }
        let responder = window.firstResponder
        if responder === self || responder === currentEditor() { return }
        if hasMarkedText(in: responder) { return }
        if hasValidTextResponder(responder) { return }
        window.makeFirstResponder(self)
    }

    private func hasMarkedText(in responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView, textView.hasMarkedText() {
            return true
        }
        if let field = responder as? NSTextField,
           let editor = field.currentEditor() as? NSTextView,
           editor.hasMarkedText() {
            return true
        }
        return false
    }

    private func hasValidTextResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView {
            return true
        }
        if let field = responder as? NSTextField, field !== self {
            if field.isEditable { return true }
            if field.currentEditor() is NSTextView { return true }
        }
        return false
    }
}

struct DecompositionIdentifiedButton: NSViewRepresentable {
    var title: String
    var identifier: String
    var accessibilityName: String
    var accessibilityValue: String = ""
    var helpText: String = ""
    var enabled: Bool = true
    var selected: Bool? = nil
    var subdued: Bool = false
    var isBordered: Bool = false
    var action: () -> Void

    func makeNSView(context: Context) -> DecompositionNSButton {
        let button = DecompositionNSButton(title: title, target: context.coordinator, action: #selector(Coordinator.run))
        button.bezelStyle = isBordered ? .rounded : .inline
        button.isBordered = isBordered
        button.setButtonType(.momentaryPushIn)
        context.coordinator.action = action
        apply(button, colorScheme: context.environment.colorScheme)
        return button
    }

    func updateNSView(_ button: DecompositionNSButton, context: Context) {
        context.coordinator.action = action
        apply(button, colorScheme: context.environment.colorScheme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    private func apply(_ button: DecompositionNSButton, colorScheme: ColorScheme) {
        button.title = title
        button.intendedEnabled = enabled
        button.isEnabled = enabled
        button.cell?.isEnabled = enabled
        button.toolTip = helpText.isEmpty ? nil : helpText
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityName)
        button.setAccessibilityTitle(accessibilityName)
        button.setAccessibilityValue(accessibilityValue.isEmpty ? nil : accessibilityValue)
        if let selected {
            button.setAccessibilitySelected(selected)
        }
        if !helpText.isEmpty {
            button.setAccessibilityHelp(helpText)
        }
        if selected == true {
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.layer?.backgroundColor = NSColor(
                CalendarTheme.appearance(for: colorScheme).selectionFill
            ).withAlphaComponent(0.55).cgColor
        } else if button.layer != nil {
            button.layer?.backgroundColor = nil
        }
        button.alphaValue = subdued ? 0.7 : 1
        button.refusesFirstResponder = !enabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

struct DecompositionMenuAction {
    var title: String
    var isDestructive: Bool = false
    var handler: () -> Void
}

struct DecompositionIdentifiedMenuButton: NSViewRepresentable {
    var title: String
    var identifier: String
    var accessibilityName: String
    var helpText: String = ""
    var enabled: Bool = true
    var items: [DecompositionMenuAction]

    func makeNSView(context: Context) -> DecompositionNSButton {
        let button = DecompositionNSButton(title: title, target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        context.coordinator.items = items
        apply(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: DecompositionNSButton, context: Context) {
        context.coordinator.items = items
        apply(button, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    private func apply(_ button: DecompositionNSButton, coordinator: Coordinator) {
        button.title = title
        button.intendedEnabled = enabled
        button.isEnabled = enabled
        button.cell?.isEnabled = enabled
        button.toolTip = helpText.isEmpty ? nil : helpText
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.menu = makeMenu(coordinator: coordinator)
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibilityName)
        button.setAccessibilityTitle(accessibilityName)
        if !helpText.isEmpty {
            button.setAccessibilityHelp(helpText)
        }
        button.refusesFirstResponder = !enabled
    }

    private func makeMenu(coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.title = DecompositionWorkbenchCopy.more
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(Coordinator.runMenuItem(_:)),
                keyEquivalent: ""
            )
            menuItem.target = coordinator
            menuItem.tag = index
            menuItem.isEnabled = enabled
            if item.isDestructive {
                menuItem.attributedTitle = NSAttributedString(
                    string: item.title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    final class Coordinator: NSObject {
        var items: [DecompositionMenuAction]
        init(items: [DecompositionMenuAction]) { self.items = items }

        @MainActor
        @objc func showMenu(_ sender: NSButton) {
            guard let menu = sender.menu else { return }
            let point = NSPoint(x: 0, y: sender.bounds.height)
            menu.popUp(positioning: nil, at: point, in: sender)
        }

        @objc func runMenuItem(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].handler()
        }
    }
}

struct DecompositionIdentifiedCheckbox: NSViewRepresentable {
    @Binding var isOn: Bool
    var identifier: String
    var accessibilityName: String
    var visualTitle: String = ""
    var enabled: Bool = true

    func makeNSView(context: Context) -> DecompositionNSButton {
        let button = DecompositionNSButton(frame: .zero)
        button.setButtonType(.switch)
        button.title = visualTitle
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggle(_:))
        button.allowsMixedState = false
        button.imagePosition = .imageLeading
        context.coordinator.onChange = { isOn = $0 }
        apply(button)
        return button
    }

    func updateNSView(_ button: DecompositionNSButton, context: Context) {
        context.coordinator.onChange = { isOn = $0 }
        apply(button)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DecompositionNSButton,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { isOn = $0 })
    }

    private func apply(_ button: DecompositionNSButton) {
        if button.title != visualTitle {
            button.title = visualTitle
        }
        let desired: NSControl.StateValue = isOn ? .on : .off
        if button.state != desired {
            button.state = desired
        }
        button.intendedEnabled = enabled
        button.isEnabled = enabled
        button.cell?.isEnabled = enabled
        if identifier.isEmpty {
            button.identifier = nil
            button.setAccessibilityIdentifier(nil)
        } else {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.setAccessibilityIdentifier(identifier)
        }
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilityLabel(accessibilityName)
        button.setAccessibilityTitle(accessibilityName)
        button.setAccessibilityValue(NSNumber(value: button.state == .on ? 1 : 0))
        button.cell?.setAccessibilityElement(false)
        button.refusesFirstResponder = !enabled
    }

    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @MainActor
        @objc func toggle(_ sender: NSButton) {
            onChange(sender.state == .on)
        }
    }
}

final class DecompositionWrappingLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        let width = max(bounds.width, preferredMaxLayoutWidth, 40)
        return sizeThatFits(NSSize(width: width, height: 10_000))
    }
}

struct DecompositionIdentifiedTextField: NSViewRepresentable {
    @Binding var text: String
    var identifier: String
    var accessibilityName: String
    var placeholder: String = ""
    var requestsInitialFocus: Bool = false
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = DecompositionIdentifiedNSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 14)
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.requestsInitialFocus = requestsInitialFocus
        context.coordinator.onSubmit = onSubmit
        apply(field, isEnabled: context.environment.isEnabled)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if let identified = field as? DecompositionIdentifiedNSTextField {
            identified.requestsInitialFocus = requestsInitialFocus
        }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.delegate = context.coordinator
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onChange = { text = $0 }
        apply(field, isEnabled: context.environment.isEnabled)
        if let identified = field as? DecompositionIdentifiedNSTextField {
            identified.attemptInitialFocusIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 }, onSubmit: onSubmit)
    }

    private func apply(_ field: NSTextField, isEnabled: Bool) {
        field.isEnabled = isEnabled
        field.cell?.isEnabled = isEnabled
        field.refusesFirstResponder = !isEnabled
        field.focusRingType = .default
        field.cell?.focusRingType = .default
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(accessibilityName)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        var onSubmit: () -> Void

        init(onChange: @escaping (String) -> Void, onSubmit: @escaping () -> Void) {
            self.onChange = onChange
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                control.window?.selectKeyView(following: control)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                control.window?.selectKeyView(preceding: control)
                return true
            }
            return false
        }
    }
}

final class DecompositionMultilineNSTextField: NSTextField {
    static let minLines = 2
    static let maxLines = 6

    override var acceptsFirstResponder: Bool { isEditable && isEnabled }
    override var canBecomeKeyView: Bool { isEditable && isEnabled && !isHiddenOrHasHiddenAncestor }

    override var intrinsicContentSize: NSSize {
        let fitted = sizeThatFits(
            NSSize(width: max(bounds.width, preferredMaxLayoutWidth, 40), height: 10_000)
        )
        return NSSize(width: NSView.noIntrinsicMetric, height: fitted.height)
    }

    override func sizeThatFits(_ size: NSSize) -> NSSize {
        let width = size.width > 1 && size.width < 9_000
            ? size.width
            : max(bounds.width, preferredMaxLayoutWidth, 40)
        let measured = cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)
        ) ?? super.sizeThatFits(NSSize(width: width, height: 10_000))
        let lineHeight = Self.lineHeight(for: font)
        let height = min(
            max(measured.height, lineHeight * CGFloat(Self.minLines)),
            lineHeight * CGFloat(Self.maxLines)
        )
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        if bounds.width > 1, abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    static func lineHeight(for font: NSFont?) -> CGFloat {
        let resolved = font ?? .systemFont(ofSize: 12)
        return ceil(resolved.boundingRectForFont.height)
    }
}

struct DecompositionIdentifiedMultilineTextField: NSViewRepresentable {
    @Binding var text: String
    var identifier: String
    var accessibilityName: String
    var placeholder: String

    func makeNSView(context: Context) -> DecompositionMultilineNSTextField {
        let field = DecompositionMultilineNSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .default
        field.cell?.focusRingType = .default
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = Self.maxVisibleLines
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.delegate = context.coordinator
        field.stringValue = text
        apply(field, isEnabled: context.environment.isEnabled)
        return field
    }

    func updateNSView(_ field: DecompositionMultilineNSTextField, context: Context) {
        context.coordinator.onChange = { text = $0 }
        apply(field, isEnabled: context.environment.isEnabled)
        field.placeholderString = placeholder
        let hasMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, field.stringValue != text {
            field.stringValue = text
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DecompositionMultilineNSTextField,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? max(nsView.bounds.width, 40)
        nsView.preferredMaxLayoutWidth = width
        return nsView.sizeThatFits(NSSize(width: width, height: 10_000))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 })
    }

    private func apply(_ field: DecompositionMultilineNSTextField, isEnabled: Bool) {
        field.isEnabled = isEnabled
        field.cell?.isEnabled = isEnabled
        field.focusRingType = .default
        field.cell?.focusRingType = .default
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.textField)
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(accessibilityName)
        field.cell?.setAccessibilityElement(false)
    }

    private static let maxVisibleLines = DecompositionMultilineNSTextField.maxLines

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
            field.invalidateIntrinsicContentSize()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                control.window?.selectKeyView(following: control)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                control.window?.selectKeyView(preceding: control)
                return true
            }
            return false
        }
    }
}

struct DecompositionAccessibleLabel: NSViewRepresentable {
    var text: String
    var identifier: String = ""
    var label: String? = nil

    func makeNSView(context: Context) -> DecompositionWrappingLabel {
        let field = DecompositionWrappingLabel()
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(field)
        return field
    }

    func updateNSView(_ field: DecompositionWrappingLabel, context: Context) {
        field.stringValue = text
        if field.bounds.width > 1 {
            field.preferredMaxLayoutWidth = field.bounds.width
            field.invalidateIntrinsicContentSize()
        }
        apply(field)
    }

    private func apply(_ field: NSTextField) {
        if !identifier.isEmpty {
            field.setAccessibilityIdentifier(identifier)
        }
        field.setAccessibilityLabel(label ?? text)
        field.setAccessibilityRole(.staticText)
    }
}

enum DecompositionWorkbenchMetrics {
    static let targetSize = CGSize(width: 960, height: 680)
    static let minimumSize = CGSize(width: 720, height: 560)
    static let stackedBreakpoint: CGFloat = 760
    static let conversationRatio: CGFloat = 0.34
    static let resultHeight: CGFloat = 64
}

enum DecompositionTypography {
    static let functionTitle = Font.system(size: 16, weight: .semibold)
    static let sectionTitle = Font.system(size: 15, weight: .medium)
    static let body = Font.system(size: 14)
    static let auxiliary = Font.system(size: 12)
}

enum DecompositionWorkbenchCopy {
    static let workbenchTitle = "拆开并安排"
    static let continueAnswer = "继续"
    static let discardDraft = "丢弃这次拆解"
    static let continueEditing = "继续编辑"
    static let discardDraftMessage = "这份草稿不会保存"
    static let source = "来源"
    static let actions = "行动草稿"
    static let schedule = "安排时间"
    static let organizing = "正在整理…"
    static let stop = "停止"
    static let stopHelp = "停止这次整理"
    static let committing = "正在创建行动…"
    static let addAction = "添加行动"
    static let continueSplit = "继续拆开"
    static let continueSplitHelp = "只把这一项继续拆开，其他行动保持不变"
    static let moveUp = "上移行动"
    static let moveDown = "下移行动"
    static let dragHandleHelp = "拖动以调整行动顺序"
    static let more = "更多操作"
    static let confirmActions = "确认行动"
    static let refreshProposals = "重新建议时间"
    static let noProposal = "暂无建议"
    static let joinCalendar = "加入日历"
    static let keepAction = "保留为行动"

    static func stageTitle(_ stage: DecompositionStage) -> String {
        switch stage {
        case .understand: "理解"
        case .split: "拆开"
        case .schedule: "安排"
        }
    }

    static func stageValue(isCurrent: Bool, isCompleted: Bool) -> String {
        if isCurrent { return "当前步骤" }
        if isCompleted { return "已完成步骤" }
        return "未到达步骤"
    }

    static func commitTitle(created: Int, scheduled: Int) -> String {
        if created == 0 { return "至少保留一个行动" }
        if scheduled == 0 { return "创建 \(created) 个行动，暂不安排" }
        return "创建 \(created) 个行动，并安排其中 \(scheduled) 个"
    }

    static func completionMessage(created: Int, scheduled: Int) -> String {
        if scheduled == 0 { return "已创建 \(created) 个行动" }
        return "已创建 \(created) 个行动，并安排其中 \(scheduled) 个"
    }

    static func collapsedActionAccessibilityLabel(
        title: String,
        completion: String,
        minutes: Int
    ) -> String {
        let displayTitle = title.isEmpty ? "未命名行动" : title
        let displayCompletion = completion.isEmpty ? "还没有完成说明" : completion
        return "\(displayTitle)，\(displayCompletion)，预计 \(minutes) 分钟"
    }

    static func blockingReason(_ reason: DecompositionWorkbenchBlockingReason) -> String {
        switch reason {
        case .sourceChanged:
            "请关闭工作台，确认最新笔记后重新打开。"
        case .noSelectedActions:
            "请至少勾选一个行动后再继续。"
        case .missingTitle(let count):
            "还有 \(count) 个行动没有标题，请补全后再继续。"
        case .missingCompletion(let count):
            "还有 \(count) 个行动没有完成说明，请补全后再继续。"
        case .missingCalendarProposal(let count):
            "还有 \(count) 个行动未选择时间，请选择时间或取消加入日历。"
        }
    }

    static func recoverableError(_ error: DecompositionRecoverableError) -> String? {
        switch error {
        case .sourceChanged:
            blockingReason(.sourceChanged)
        case .calendarConflict:
            "日历出现新的时间冲突，请调整日期或时间，或取消加入日历后再确认。"
        case .persistenceFailed:
            "原笔记和日历没有被改动，可稍后重试。"
        case .planningFailed:
            "这次整理没有完成，你仍可手动添加和安排行动"
        case .requestCancelled:
            nil
        }
    }

    static func manualBanner(for reason: ManualDecompositionReason) -> String {
        switch reason {
        case .systemVersionUnsupported:
            "当前系统版本不支持智能拆解，你仍可手动添加和安排行动"
        case .deviceNotEligible:
            "这台设备不支持智能拆解，你仍可手动添加和安排行动"
        case .appleIntelligenceNotEnabled:
            "尚未开启 Apple 智能，你仍可手动添加和安排行动"
        case .modelNotReady:
            "智能拆解模型还在准备中，你仍可手动添加和安排行动"
        case .localeUnsupported:
            "当前语言不支持智能拆解，你仍可手动添加和安排行动"
        case .timedOut:
            "这次整理超时了，你仍可手动添加和安排行动"
        case .repeatedInvalidOutput:
            "这次整理结果不可靠，你仍可手动添加和安排行动"
        case .modelFailure:
            "智能拆解失败了，你仍可手动添加和安排行动"
        }
    }

    static func resultSummary(
        isCommitting: Bool,
        blockingReason: DecompositionWorkbenchBlockingReason?,
        lastRecoverableError: DecompositionRecoverableError?,
        created: Int,
        scheduled: Int
    ) -> String {
        if isCommitting {
            return committing
        }
        if let blockingReason {
            return self.blockingReason(blockingReason)
        }
        if let lastRecoverableError, let message = recoverableError(lastRecoverableError) {
            return message
        }
        return commitTitle(created: created, scheduled: scheduled)
    }
}

struct DecompositionWorkbenchSessionView: View {
    @Bindable var model: DecompositionWorkbenchModel
    let onCancel: () -> Void
    let onCommitted: (DecompositionCommitResult) -> Void

    var body: some View {
        DecompositionWorkbenchView(
            model: model,
            onCancel: onCancel,
            onCommitted: onCommitted
        )
        .task { await model.start() }
    }
}

struct DecompositionWorkbenchView: View {
    @Bindable var model: DecompositionWorkbenchModel
    let onCancel: () -> Void
    let onCommitted: (DecompositionCommitResult) -> Void
    @State private var showsDiscardConfirmation = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var motion: CalendarMotionPolicy {
        CalendarMotionPolicy(reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(spacing: 0) {
            stageNavigation
            ViewThatFits(in: .horizontal) {
                wideBody.frame(minWidth: DecompositionWorkbenchMetrics.stackedBreakpoint)
                stackedBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            resultBar
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .animation(motion.overlayAnimation, value: model.draft.stage)
        .animation(motion.overlayAnimation, value: model.requestState)
        .frame(
            minWidth: DecompositionWorkbenchMetrics.minimumSize.width,
            idealWidth: DecompositionWorkbenchMetrics.targetSize.width,
            minHeight: DecompositionWorkbenchMetrics.minimumSize.height,
            idealHeight: DecompositionWorkbenchMetrics.targetSize.height
        )
        .onExitCommand(perform: requestClose)
        .confirmationDialog(
            DecompositionWorkbenchCopy.discardDraft,
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(DecompositionWorkbenchCopy.discardDraft, role: .destructive) {
                onCancel()
            }
            Button(DecompositionWorkbenchCopy.continueEditing, role: .cancel) {
                showsDiscardConfirmation = false
            }
        } message: {
            Text(DecompositionWorkbenchCopy.discardDraftMessage)
        }
        .background {
            Button("") { requestClose() }
                .keyboardShortcut(.cancelAction)
                .hidden()
            if model.draft.stage == .schedule, model.canCommit, !model.isCommitting {
                Button("") { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .hidden()
            }
        }
    }

    private var stageNavigation: some View {
        HStack(spacing: 18) {
            Text(DecompositionWorkbenchCopy.workbenchTitle)
                .font(DecompositionTypography.functionTitle)
                .foregroundStyle(theme.primaryText)
                .fixedSize()
            ForEach(DecompositionStage.allCases, id: \.self) { stage in
                let isCurrent = stage == model.draft.stage
                let isCompleted = stage.rawValue < model.draft.stage.rawValue
                DecompositionIdentifiedButton(
                    title: DecompositionWorkbenchCopy.stageTitle(stage),
                    identifier: "decomposition-stage-\(stage.rawValue)",
                    accessibilityName: DecompositionWorkbenchCopy.stageTitle(stage),
                    accessibilityValue: DecompositionWorkbenchCopy.stageValue(
                        isCurrent: isCurrent,
                        isCompleted: isCompleted
                    ),
                    enabled: stage.rawValue <= model.draft.stage.rawValue && !model.isCommitting,
                    selected: isCurrent,
                    subdued: isCompleted
                ) {
                    model.returnToStage(stage)
                }
                .frame(width: 44, height: 22)
            }
            Spacer()
            DecompositionIdentifiedButton(
                title: "关闭",
                identifier: "decomposition-close",
                accessibilityName: "关闭",
                helpText: "关闭工作台，不保存这次拆解",
                enabled: !model.isCommitting
            ) {
                requestClose()
            }
            .frame(width: 44, height: 22)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    private var wideBody: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                conversationPane
                    .frame(width: proxy.size.width * DecompositionWorkbenchMetrics.conversationRatio)
                Rectangle().fill(theme.separator).frame(width: 1)
                editorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var stackedBody: some View {
        VStack(spacing: 0) {
            conversationPane
                .frame(minHeight: 168, maxHeight: 220)
            Rectangle().fill(theme.separator).frame(height: 1)
            editorPane
        }
    }

    private var conversationPane: some View {
        DecompositionConversationPane(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.conversationSurface)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(DecompositionWorkbenchCopy.source)
            .accessibilityIdentifier("decomposition-conversation")
    }

    @ViewBuilder
    private var editorPane: some View {
        Group {
            if model.draft.stage == .schedule {
                DecompositionScheduleEditor(model: model)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(DecompositionWorkbenchCopy.schedule)
                    .accessibilityIdentifier("decomposition-schedule")
            } else {
                DecompositionActionEditor(model: model)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(DecompositionWorkbenchCopy.actions)
                    .accessibilityIdentifier("decomposition-actions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.elevatedSurface)
    }

    private var resultBar: some View {
        HStack(spacing: 12) {
            DecompositionAccessibleLabel(
                text: resultSummary,
                identifier: "decomposition-result-summary",
                label: resultSummary
            )
            Spacer(minLength: 12)
            if model.draft.stage == .split {
                DecompositionIdentifiedButton(
                    title: DecompositionWorkbenchCopy.confirmActions,
                    identifier: "decomposition-advance",
                    accessibilityName: DecompositionWorkbenchCopy.confirmActions,
                    enabled: model.canAdvance && !model.isCommitting,
                    isBordered: true
                ) {
                    model.advanceToSchedule()
                }
                .frame(minWidth: 88, maxHeight: 28)
            }
            if model.draft.stage == .schedule {
                DecompositionIdentifiedButton(
                    title: commitTitle,
                    identifier: "decomposition-commit",
                    accessibilityName: commitTitle,
                    enabled: model.canCommit && !model.isCommitting,
                    isBordered: true
                ) {
                    Task { await commit() }
                }
                .id("commit-\(commitTitle)-\(createdCount)-\(model.canCommit)")
                .frame(minWidth: 160, maxHeight: 28)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: DecompositionWorkbenchMetrics.resultHeight)
        .background(theme.elevatedSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
        .accessibilityIdentifier("decomposition-result")
        .allowsHitTesting(!model.isCommitting || model.draft.stage != .schedule)
    }

    private var createdCount: Int {
        model.draft.candidates.filter(\.selectedForCreation).count
    }

    private var scheduledCount: Int {
        model.draft.candidates.filter {
            $0.selectedForCreation && $0.selectedForCalendar && $0.proposal != nil
        }.count
    }

    private var commitTitle: String {
        DecompositionWorkbenchCopy.commitTitle(created: createdCount, scheduled: scheduledCount)
    }

    private var resultSummary: String {
        DecompositionWorkbenchCopy.resultSummary(
            isCommitting: model.isCommitting,
            blockingReason: stageBlockingReason,
            lastRecoverableError: model.draft.lastRecoverableError,
            created: createdCount,
            scheduled: scheduledCount
        )
    }

    private var stageBlockingReason: DecompositionWorkbenchBlockingReason? {
        switch model.draft.stage {
        case .understand, .split:
            model.advanceBlockingReason
        case .schedule:
            model.commitBlockingReason
        }
    }

    private func requestClose() {
        if model.isCommitting { return }
        if model.hasRunningRequest {
            model.cancelRequest()
            return
        }
        if model.hasMeaningfulDraft {
            showsDiscardConfirmation = true
            return
        }
        onCancel()
    }

    private func commit() async {
        guard !model.isCommitting else { return }
        let result = await model.commit()
        if case .committed = result {
            onCommitted(result)
        }
    }
}
