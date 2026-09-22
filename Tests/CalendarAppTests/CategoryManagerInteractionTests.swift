import AppKit
import SwiftUI
import Testing
@testable import CalendarApp

@Suite("CategoryManagerInteractionTests")
@MainActor
struct CategoryManagerInteractionTests {
    @Test func successfulNoChangeSaveClosesTheManager() async throws {
        var state = makeEmptyState()
        let travel = makeCategory(name: "Travel")
        state.categories[travel.id] = travel
        let (store, _) = try await makeReadyStore(initialState: state)
        var closeCount = 0
        let hosted = hostCategoryManager(
            store: store,
            initialCategoryID: travel.id,
            onClose: { closeCount += 1 }
        )
        defer { hosted.window.orderOut(nil) }

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(hosted.window.performKeyEquivalent(with: returnKey))

        #expect(await waitForCategoryCondition { closeCount == 1 })
        #expect(store.calendarState.categories[travel.id] == travel)
    }
}

private final class CategoryManagerTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKey()
    }

    override func orderFront(_ sender: Any?) {}
    override func orderFrontRegardless() {}
}

@MainActor
private func hostCategoryManager(
    store: WorkspaceStore,
    initialCategoryID: UUID?,
    onClose: @escaping () -> Void
) -> (view: NSHostingView<CategoryManagerView>, window: NSWindow) {
    _ = NSApplication.shared
    let root = CategoryManagerView(
        store: store,
        initialCategoryID: initialCategoryID,
        onClose: onClose
    )
    let hosting = NSHostingView(rootView: root)
    hosting.frame = CGRect(x: 0, y: 0, width: 680, height: 760)
    let window = CategoryManagerTestWindow(
        contentRect: hosting.frame,
        styleMask: [],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.animationBehavior = .none
    window.contentView = hosting
    window.makeKey()
    hosting.layoutSubtreeIfNeeded()
    window.recalculateKeyViewLoop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return (hosting, window)
}

@MainActor
private func waitForCategoryCondition(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
