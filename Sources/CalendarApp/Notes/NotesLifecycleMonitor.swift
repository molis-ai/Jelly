import AppKit
import SwiftUI

@MainActor
final class NotesWindowCloseCoordinator: NSObject, NSWindowDelegate {
    typealias Decision = @MainActor () async -> NoteCloseProtectionDecision
    typealias ClosePerformer = @MainActor (NSWindow) -> Void

    private var decision: Decision
    private let closePerformer: ClosePerformer
    private weak var attachedWindow: NSWindow?
    nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?
    private var closeRequestInFlight = false
    private var authorizedClosePending = false

    init(
        decision: @escaping Decision,
        closePerformer: @escaping ClosePerformer = { $0.performClose(nil) }
    ) {
        self.decision = decision
        self.closePerformer = closePerformer
    }

    func updateDecision(_ decision: @escaping Decision) {
        self.decision = decision
    }

    func attach(to window: NSWindow?) {
        guard attachedWindow !== window else { return }
        detach()
        guard let window else { return }
        attachedWindow = window
        previousDelegate = window.delegate
        window.delegate = self
    }

    func detach() {
        if let attachedWindow, attachedWindow.delegate === self {
            attachedWindow.delegate = previousDelegate
        }
        attachedWindow = nil
        previousDelegate = nil
        closeRequestInFlight = false
        authorizedClosePending = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if authorizedClosePending {
            authorizedClosePending = false
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        guard closeRequestInFlight == false else { return false }
        if attachedWindow == nil { attachedWindow = sender }
        closeRequestInFlight = true
        let decision = decision
        Task { @MainActor [weak self, weak sender] in
            let result = await decision()
            guard let self else { return }
            self.closeRequestInFlight = false
            guard result == .allow,
                  let sender,
                  self.attachedWindow === sender
            else { return }
            self.authorizedClosePending = true
            self.closePerformer(sender)
        }
        return false
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true { return previousDelegate }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
final class NotesApplicationTerminationCoordinator: NSObject, NSApplicationDelegate {
    typealias Decision = @MainActor () async -> NoteCloseProtectionDecision
    typealias Reply = @MainActor (Bool) -> Void

    private var decision: Decision
    private let reply: Reply
    private var pendingDecision: Task<Void, Never>?

    override init() {
        decision = { .allow }
        reply = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
        super.init()
    }

    init(decision: @escaping Decision, reply: @escaping Reply) {
        self.decision = decision
        self.reply = reply
        super.init()
    }

    func updateDecision(_ decision: @escaping Decision) {
        self.decision = decision
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard pendingDecision == nil else { return .terminateLater }
        let decision = decision
        pendingDecision = Task { @MainActor [weak self] in
            let result = await decision()
            guard let self else { return }
            self.pendingDecision = nil
            self.reply(result == .allow)
        }
        return .terminateLater
    }
}

private final class NotesWindowCloseAnchorView: NSView {
    weak var closeCoordinator: NotesWindowCloseCoordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        closeCoordinator?.attach(to: window)
    }
}

struct NotesWindowCloseMonitor: NSViewRepresentable {
    let bridge: NoteCloseProtectionBridge
    let finalizerSlot: NotesNativeFinalizerSlot

    func makeCoordinator() -> NotesWindowCloseCoordinator {
        NotesWindowCloseCoordinator {
            await bridge.decision(for: .windowClose, finalizer: finalizerSlot.value)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NotesWindowCloseAnchorView(frame: .zero)
        view.setAccessibilityElement(false)
        view.closeCoordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateDecision {
            await bridge.decision(for: .windowClose, finalizer: finalizerSlot.value)
        }
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: NotesWindowCloseCoordinator) {
        coordinator.detach()
    }
}
