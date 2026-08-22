import AppKit
import Foundation

@MainActor
protocol ContinuousBlockEditorHost: AnyObject {
    var textView: ContinuousBlockEditorTextView { get }
    var semanticAppearance: CalendarSemanticAppearance { get }
    var completionDescriptionWidth: CGFloat { get }
    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    )
}

extension ContinuousBlockEditorHost {
    var completionDescriptionWidth: CGFloat {
        max(1, textView.bounds.width - BlockTextStyle.textColumnOffset(for: .task) - 10)
    }
}

@MainActor
final class ContinuousBlockEditorHostView: NSView, ContinuousBlockEditorHost {
    let textView = ContinuousBlockEditorTextView(frame: .zero)
    let taskCheckboxOverlay = TaskBlockCheckboxOverlay(frame: .zero)
    let taskCompletionDescriptionOverlay = TaskBlockCompletionDescriptionOverlay(frame: .zero)
    var semanticAppearance: CalendarSemanticAppearance {
        didSet { needsLayout = true }
    }
    var completionDescriptionWidth: CGFloat {
        max(1, bounds.width - BlockTextStyle.textColumnOffset(for: .task) - 10)
    }
    private var measuredHeight: CGFloat = 80
    private var measuredWidth: CGFloat?
    private var lastProjectedCompletionWidth: CGFloat?
    private var deferredLayoutTask: Task<Void, Never>?

    init(appearance: CalendarSemanticAppearance) {
        semanticAppearance = appearance
        super.init(frame: .zero)
        addSubview(textView)
        addSubview(taskCheckboxOverlay)
        addSubview(taskCompletionDescriptionOverlay)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        semanticAppearance = CalendarTheme.light
        super.init(coder: coder)
        addSubview(textView)
        addSubview(taskCheckboxOverlay)
        addSubview(taskCompletionDescriptionOverlay)
        setAccessibilityElement(false)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        .init(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        textView.frame = .init(x: 0, y: 0, width: width, height: max(measuredHeight, bounds.height))
        taskCheckboxOverlay.frame = textView.frame
        taskCompletionDescriptionOverlay.frame = textView.frame
        if !taskCompletionDescriptionOverlay.subviews.isEmpty,
           !textView.hasMarkedText(),
           lastProjectedCompletionWidth.map({ abs($0 - completionDescriptionWidth) > 0.5 }) ?? true {
            textView.attachedSession?.projectAuthoritativeState()
        }
        if measuredWidth.map({ abs($0 - width) > 0.5 }) ?? true {
            updateMeasuredHeight(width: width)
            taskCheckboxOverlay.updateFrames()
            taskCompletionDescriptionOverlay.updateFrames()
        }
    }

    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        lastProjectedCompletionWidth = completionDescriptionWidth
        textView.apply(diff: diff, projection: projection, selectedRange: selectedRange)
        let needsImmediateLayout = diff == nil
        taskCheckboxOverlay.apply(
            document: projection.document,
            textView: textView,
            updateFramesImmediately: needsImmediateLayout
        )
        taskCompletionDescriptionOverlay.apply(
            document: projection.document,
            textView: textView,
            appearance: semanticAppearance,
            updateFramesImmediately: needsImmediateLayout
        )
        if needsImmediateLayout {
            deferredLayoutTask?.cancel()
            updateMeasuredHeight(width: max(1, bounds.width))
        } else {
            scheduleDeferredContentLayout()
        }
    }

    private func updateMeasuredHeight(width: CGFloat) {
        measuredWidth = width
        let textHeight = max(80, textView.measuredContentHeight(for: width))
        let layoutHeight = max(textHeight, bounds.height, measuredHeight)
        textView.frame.size.height = layoutHeight
        taskCheckboxOverlay.frame.size.height = layoutHeight
        taskCompletionDescriptionOverlay.frame.size.height = layoutHeight
        taskCheckboxOverlay.updateFrames()
        taskCompletionDescriptionOverlay.updateFrames()
        let next = max(textHeight, taskCompletionDescriptionOverlay.requiredContentHeight())
        guard abs(next - measuredHeight) > 0.5 else { return }
        measuredHeight = next
        textView.frame.size.height = next
        taskCheckboxOverlay.frame.size.height = next
        taskCompletionDescriptionOverlay.frame.size.height = next
        taskCheckboxOverlay.updateFrames()
        taskCompletionDescriptionOverlay.updateFrames()
        invalidateIntrinsicContentSize()
        // The first reveal request happens before the debounced full height is
        // known. Once the outer SwiftUI ScrollView receives the new intrinsic
        // height, ask again so the actual caret—not the old document frame—is
        // brought into view after a burst of typing.
        textView.requestSelectionRevealIfFocused()
    }

    private func scheduleDeferredContentLayout() {
        deferredLayoutTask?.cancel()
        deferredLayoutTask = Task { @MainActor [weak self] in
            do {
                // Height and checkbox geometry are maintenance work, not part
                // of showing the typed character. Debounce them so a burst of
                // keystrokes performs one whole-document layout after typing
                // pauses instead of one layout per character.
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.updateMeasuredHeight(width: max(1, self.bounds.width))
            self.taskCheckboxOverlay.updateFrames()
            self.taskCompletionDescriptionOverlay.updateFrames()
            self.deferredLayoutTask = nil
        }
    }
}
