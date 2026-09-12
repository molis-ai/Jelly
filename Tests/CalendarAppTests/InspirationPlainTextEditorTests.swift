import AppKit
import CalendarDomain
import SwiftUI
import Testing
@testable import CalendarApp

@Suite("InspirationPlainTextEditorTests")
@MainActor
struct InspirationPlainTextEditorTests {
    @Test func parentRefreshDoesNotOverwriteMarkedTextOrMoveTheCaret() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "做移动端 jelly，不然")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.setMarkedText(
            "ling",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())
        let marked = textView.string
        #expect(marked.hasPrefix("做移动端 jelly，不然"))
        #expect(marked.contains("ling"))
        #expect(harness.text == "做移动端 jelly，不然")

        harness.refreshToken += 1
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))

        let afterRefresh = try #require(editorTextView(in: host.view))
        #expect(afterRefresh.hasMarkedText())
        #expect(afterRefresh.string == marked)
        #expect(harness.text == "做移动端 jelly，不然")
    }

    @Test func committingCompositionUpdatesTheBindingOnce() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "做移动端 jelly，不然")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.setMarkedText(
            "ling",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())
        textView.insertText("灵", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText() == false)
        #expect(textView.string == "做移动端 jelly，不然灵")
        #expect(harness.text == "做移动端 jelly，不然灵")
    }

    @Test func sameExternalTextDoesNotResetTheCaret() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "先记一句")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        harness.refreshToken += 1
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))

        let afterRefresh = try #require(editorTextView(in: host.view))
        #expect(afterRefresh.string == "先记一句")
        #expect(afterRefresh.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test func sameExternalTextPreservesSelectionLength() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "先记一句")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 1, length: 2))

        harness.refreshToken += 1
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))

        let afterRefresh = try #require(editorTextView(in: host.view))
        #expect(afterRefresh.selectedRange == NSRange(location: 1, length: 2))
    }

    @Test func focusedTypingUndoDoesNotFallThroughToWorkspace() async throws {
        _ = NSApplication.shared
        let original = makeEmptyState()
        let (store, _) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "添加事项")

        let harness = InspirationEditorHarness(text: "原始正文")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText("补一句", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.text == "原始正文补一句")
        #expect(harness.focusRegistry.availability != .noFocusedOwner)

        let route = try await CalendarUndoCommandRouter.undo(
            store: store,
            focusRegistry: harness.focusRegistry
        )
        #expect(route == .focusedPerformed)
        #expect(harness.text == "原始正文")
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func blurReleasesFocusSoWorkspaceUndoCanRun() async throws {
        _ = NSApplication.shared
        let original = makeEmptyState()
        let (store, _) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "添加事项")

        let harness = InspirationEditorHarness(text: "原始正文")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.focusRegistry.availability != .noFocusedOwner)

        #expect(host.window.makeFirstResponder(host.view))
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.focusRegistry.availability == .noFocusedOwner)

        #expect(try await CalendarUndoCommandRouter.undo(
            store: store,
            focusRegistry: harness.focusRegistry
        ) == .noFocusedOwner)
        #expect(store.calendarState.items[item.id] == nil)
    }

    @Test func dismantleClearsTheFocusLease() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "原始正文")
        let host = hostedEditor(harness)
        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.focusRegistry.availability != .noFocusedOwner)

        host.window.contentView = NSView(frame: host.window.contentView?.frame ?? .zero)
        host.window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.focusRegistry.availability == .noFocusedOwner)
    }

    @Test func focusGenerationPlacesTheCaretAtTheEnd() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "先记一句")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.focusGeneration = 1
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(host.window.firstResponder === textView)
        #expect(textView.selectedRange == NSRange(location: (textView.string as NSString).length, length: 0))
    }

    @Test func fittedHeightGrowsWhenTheDraftWrapsToAnotherLine() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "一行")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        let oneLine = harness.fittedHeight
        #expect(oneLine > 0)

        harness.text = "一行\n二行\n三行"
        host.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.fittedHeight > oneLine)
    }

    @Test func fittingHeightClearsDescendersOnAn18PointLine() {
        let textView = InspirationContentTextView()
        textView.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        textView.defaultParagraphStyle = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            return paragraph
        }()
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = "toolify, watcha 这类产品也要考虑上"
        textView.setFrameSize(NSSize(width: 520, height: 20))
        let font = NSFont.systemFont(ofSize: 18, weight: .regular)
        let glyphHeight = ceil(font.ascender - font.descender)
        let height = InspirationContentTextView.fittingHeight(for: textView)
        #expect(height >= glyphHeight + 8)
    }

    @Test func pasteInsertsPlainTextFromRichPasteboard() async throws {
        _ = NSApplication.shared
        let harness = InspirationEditorHarness(text: "开头")
        let host = hostedEditor(harness)
        defer { host.window.orderOut(nil) }

        let textView = try #require(editorTextView(in: host.view))
        #expect(host.window.makeFirstResponder(textView))
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))

        let rich = NSAttributedString(
            string: "加粗粘贴",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]
        )
        let rtf = try #require(rich.rtf(from: NSRange(location: 0, length: rich.length)))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        #expect(pasteboard.setData(rtf, forType: .rtf))
        #expect(pasteboard.setString("加粗粘贴", forType: .string))
        textView.paste(nil)

        #expect(textView.string == "开头加粗粘贴")
        #expect(harness.text == "开头加粗粘贴")
        let font = textView.textStorage?.attribute(
            .font,
            at: (textView.string as NSString).length - 1,
            effectiveRange: nil
        ) as? NSFont
        #expect(font?.pointSize == 18)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) != true)
    }
}

@MainActor
@Observable
private final class InspirationEditorHarness {
    var text: String
    var refreshToken = 0
    var focusGeneration: UInt = 0
    var fittedHeight: CGFloat = 0
    let focusRegistry = EditorFocusRegistry()

    init(text: String) {
        self.text = text
    }
}

private struct HostedInspirationEditor: View {
    @Bindable var harness: InspirationEditorHarness

    var body: some View {
        VStack {
            InspirationPlainTextEditor(
                text: Binding(
                    get: { harness.text },
                    set: { harness.text = $0 }
                ),
                textColor: .primary,
                focusRegistry: harness.focusRegistry,
                focusGeneration: harness.focusGeneration,
                fittedHeight: $harness.fittedHeight
            )
            .frame(width: 440, height: 160)
            Text(String(harness.refreshToken))
                .hidden()
        }
        .frame(width: 480, height: 200)
    }
}

@MainActor
private func hostedEditor(
    _ harness: InspirationEditorHarness
) -> (view: NSHostingView<HostedInspirationEditor>, window: NSWindow) {
    let hosting = NSHostingView(rootView: HostedInspirationEditor(harness: harness))
    hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 200)
    let window = InspirationEditorKeyWindow(
        contentRect: hosting.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    return (hosting, window)
}

@MainActor
private func editorTextView(in root: NSView) -> InspirationContentTextView? {
    if let match = root as? InspirationContentTextView { return match }
    for child in root.subviews {
        if let match = editorTextView(in: child) { return match }
    }
    return nil
}

private final class InspirationEditorKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
