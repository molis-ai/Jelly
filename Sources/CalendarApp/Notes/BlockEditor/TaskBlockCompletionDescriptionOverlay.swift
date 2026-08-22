import AppKit
import Foundation
import WorkspaceDomain

enum TaskCompletionDescriptionMetrics {
    static let topGap: CGFloat = 3
    static let bottomGap: CGFloat = 6
    static let completedOpacity: CGFloat = 0.55

    static func font() -> NSFont {
        NSFont.systemFont(ofSize: 12)
    }

    static func measuredHeight(for text: String, width: CGFloat) -> CGFloat {
        let constrained = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        let bounds = (text as NSString).boundingRect(
            with: constrained,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font()]
        )
        return max(1, ceil(bounds.height))
    }

    static func reservedParagraphSpacing(for text: String, width: CGFloat) -> CGFloat {
        measuredHeight(for: text, width: width) + topGap + bottomGap
    }

    static func reservedParagraphSpacing(
        for block: DocumentBlock,
        width: CGFloat
    ) -> CGFloat? {
        guard block.kind == .task,
              let description = block.taskState?.completionDescription else { return nil }
        return reservedParagraphSpacing(
            for: description,
            width: layoutWidth(hostWidth: width, indentLevel: block.indentLevel)
        )
    }

    static func layoutWidth(hostWidth: CGFloat, indentLevel: Int) -> CGFloat {
        max(1, hostWidth - CGFloat(max(0, indentLevel) * 20))
    }
}

@MainActor
final class TaskBlockCompletionDescriptionOverlay: NSView {
    private weak var textView: ContinuousBlockEditorTextView?
    private var document: BlockDocument = .init(blocks: [])
    private var labels: [BlockID: TaskCompletionDescriptionLabel] = [:]

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        document: BlockDocument,
        textView: ContinuousBlockEditorTextView,
        appearance: CalendarSemanticAppearance,
        updateFramesImmediately: Bool = true
    ) {
        self.document = document
        self.textView = textView
        let tasks = document.blocks.filter {
            $0.kind == .task && $0.taskState?.completionDescription != nil
        }
        let taskIDs = Set(tasks.map(\.id))
        for (blockID, label) in labels where !taskIDs.contains(blockID) {
            label.removeFromSuperview()
            labels[blockID] = nil
        }
        for task in tasks {
            let label = labels[task.id] ?? makeLabel(blockID: task.id)
            configure(label, for: task, appearance: appearance)
        }
        if updateFramesImmediately { updateFrames() }
    }

    func updateFrames() {
        guard let textView, let textContainer = textView.textContainer else { return }
        textView.layoutManager?.ensureLayout(for: textContainer)
        for task in document.blocks where task.kind == .task {
            guard let description = task.taskState?.completionDescription,
                  let label = labels[task.id] else { continue }
            let frame = labelFrame(for: task, description: description, in: textView)
            label.frame = frame
            label.preferredMaxLayoutWidth = frame.width
            label.isHidden = frame.isEmpty
        }
    }

    private func makeLabel(blockID: BlockID) -> TaskCompletionDescriptionLabel {
        let label = TaskCompletionDescriptionLabel(blockID: blockID)
        addSubview(label)
        labels[blockID] = label
        return label
    }

    private func configure(
        _ label: TaskCompletionDescriptionLabel,
        for task: DocumentBlock,
        appearance: CalendarSemanticAppearance
    ) {
        let description = task.taskState?.completionDescription ?? ""
        let completed = task.taskState?.completedAt != nil
        label.stringValue = description
        label.font = TaskCompletionDescriptionMetrics.font()
        label.textColor = BlockTextStyle.secondaryTextColor(appearance: appearance)
        label.alphaValue = completed ? TaskCompletionDescriptionMetrics.completedOpacity : 1
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("完成说明")
        label.setAccessibilityValue(description)
        label.setAccessibilityIdentifier("task-block-completion-\(task.id.rawValue.uuidString)")
    }

    private func labelFrame(
        for task: DocumentBlock,
        description: String,
        in textView: ContinuousBlockEditorTextView
    ) -> NSRect {
        let textStart = textView.textContainerOrigin.x
            + BlockTextStyle.paragraphStyle(for: .task, indentLevel: task.indentLevel).firstLineHeadIndent
        let width = max(1, textView.bounds.width - textStart - 10)
        let height = TaskCompletionDescriptionMetrics.measuredHeight(for: description, width: width)
        let y = titleBottomY(for: task.id, in: textView) + TaskCompletionDescriptionMetrics.topGap
        return NSRect(x: textStart, y: y, width: width, height: height)
    }

    private func titleBottomY(for blockID: BlockID, in textView: ContinuousBlockEditorTextView) -> CGFloat {
        if let used = lastUsedLineFragment(for: blockID, in: textView) {
            return used.maxY
        }
        if let checkbox = textView.taskCheckboxFrame(for: blockID) {
            return checkbox.maxY
        }
        return 0
    }

    private func lastUsedLineFragment(
        for blockID: BlockID,
        in textView: ContinuousBlockEditorTextView
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
            return nil
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: contentRange,
            actualCharacterRange: nil
        )
        var last: NSRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            last = usedRect.offsetBy(dx: origin.x, dy: origin.y)
        }
        return last
    }
}

@MainActor
private final class TaskCompletionDescriptionLabel: NSTextField {
    let blockID: BlockID

    init(blockID: BlockID) {
        self.blockID = blockID
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        refusesFirstResponder = true
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        alignment = .left
        font = TaskCompletionDescriptionMetrics.font()
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }
}
