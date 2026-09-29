import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import SwiftUI

/// A system-wide shortcut. Carbon hot keys need no Accessibility permission
/// and fire even while another app is frontmost.
struct QuickCaptureShortcut: Identifiable, Equatable, Sendable {
    let id: String
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let title: String

    static let presets: [QuickCaptureShortcut] = [
        .init(id: "ctrl-opt-j", keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey), title: "⌃⌥J"),
        .init(id: "opt-cmd-j", keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(optionKey | cmdKey), title: "⌥⌘J"),
        .init(id: "ctrl-opt-i", keyCode: UInt32(kVK_ANSI_I), carbonModifiers: UInt32(controlKey | optionKey), title: "⌃⌥I"),
        .init(id: "ctrl-shift-space", keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | shiftKey), title: "⌃⇧空格")
    ]

    static let `default` = presets[0]

    static func preset(id: String?) -> QuickCaptureShortcut? {
        presets.first { $0.id == id }
    }
}

@Observable
final class QuickCaptureSettings {
    static let enabledKey = "quickCapture.enabled.v1"
    static let shortcutKey = "quickCapture.shortcut.v1"

    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    private(set) var shortcut: QuickCaptureShortcut

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        shortcut = QuickCaptureShortcut.preset(id: defaults.string(forKey: Self.shortcutKey)) ?? .default
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
    }

    func setShortcut(_ shortcut: QuickCaptureShortcut) {
        defaults.set(shortcut.id, forKey: Self.shortcutKey)
        self.shortcut = shortcut
    }
}

@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false
    private static let signature: OSType = 0x4A_45_4C_59 // "JELY"
    private static var nextID: UInt32 = 1

    private var reference: EventHotKeyRef?
    private var identifier: UInt32 = 0

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ shortcut: QuickCaptureShortcut, handler: @escaping () -> Void) -> Bool {
        unregister()
        Self.installEventHandlerIfNeeded()
        identifier = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        reference = ref
        Self.handlers[identifier] = handler
        return true
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
        }
        reference = nil
        Self.handlers[identifier] = nil
    }

    var isRegistered: Bool { reference != nil }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard result == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                GlobalHotKey.handlers[id]?()
            }
            return noErr
        }, 1, &eventType, nil, nil)
        eventHandlerInstalled = status == noErr
    }
}

/// Borderless floating panel that takes keyboard focus without bringing the
/// Jelly window forward — the app you were in stays where it was.
final class QuickCapturePanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilityIdentifier("jelly-quick-capture")
        setAccessibilityTitle("随手记")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere puts the thought away like Spotlight does; the
        // draft stays for the next time the shortcut is pressed.
        onCancel()
    }
}

@MainActor
@Observable
final class QuickCaptureModel {
    enum Phase: Equatable {
        case editing
        case saving
        case saved
        case failed(String)
    }

    var text = ""
    private(set) var phase: Phase = .editing
    private(set) var focusGeneration = 0
    private let capture: (String) async throws -> Void

    init(capture: @escaping (String) async throws -> Void) {
        self.capture = capture
    }

    var canSubmit: Bool {
        phase != .saving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepareForShow() {
        if phase != .editing { phase = .editing }
        focusGeneration += 1
    }

    @discardableResult
    func submit() async -> Bool {
        guard canSubmit else { return false }
        phase = .saving
        do {
            try await capture(text)
            text = ""
            phase = .saved
            return true
        } catch {
            phase = .failed("没有收下，内容还在。")
            return false
        }
    }
}

struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    let shortcutTitle: String
    let onDone: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.controlAccent)
                    .padding(.top, 3)
                TextField("记下一闪而过的想法，或粘贴链接", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("quick-capture-field")
            }
            HStack(spacing: 10) {
                switch model.phase {
                case .saving:
                    Text("正在收下…")
                case .saved:
                    Label("已收下，在灵感里", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(theme.controlAccent)
                case let .failed(message):
                    Text(message).foregroundStyle(.orange)
                case .editing:
                    Text("↩ 收下 · ⌥↩ 换行 · esc 收起 · \(shortcutTitle) 随时呼出")
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.6), lineWidth: 0.5)
        )
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .onAppear { focused = true }
        .onChange(of: model.focusGeneration) { _, _ in focused = true }
    }

    private func submit() {
        Task {
            if await model.submit() {
                try? await Task.sleep(for: .milliseconds(650))
                onDone()
            }
        }
    }
}

/// Owns the hot key, the panel and the Services menu entry.
@MainActor
final class QuickCaptureCoordinator: NSObject {
    let settings: QuickCaptureSettings
    private let captureService: InspirationCaptureService
    private let hotKey = GlobalHotKey()
    private var panel: QuickCapturePanel?
    private let model: QuickCaptureModel
    private var started = false
    private(set) var registrationFailed = false
    var diagnostics: (String) -> Void = { _ in }

    init(captureService: InspirationCaptureService, settings: QuickCaptureSettings = QuickCaptureSettings()) {
        self.captureService = captureService
        self.settings = settings
        model = QuickCaptureModel { text in
            _ = try await captureService.capture(text, origin: .quickCapture)
        }
        super.init()
    }

    private static let log = Logger(subsystem: "com.oreal.personalcalendar", category: "capture")
    /// Must equal NSPortName in Info.plist (the executable name).
    static let servicesPortName = "PersonalCalendar"

    func start() {
        guard !started else { return }
        started = true
        NSApplication.shared.servicesProvider = self
        NSRegisterServicesProvider(self, Self.servicesPortName)
        NSUpdateDynamicServices()
        applySettings()
        Self.log.notice("quick capture started; hot key \(self.settings.shortcut.title, privacy: .public) registered: \(!self.registrationFailed, privacy: .public)")
    }

    /// Re-registers after the user changes the shortcut in 设置.
    func applySettings() {
        hotKey.unregister()
        registrationFailed = false
        guard settings.isEnabled else { return }
        registrationFailed = !hotKey.register(settings.shortcut) { [weak self] in
            self?.toggle()
        }
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isPanelVisible { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.prepareForShow()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickCapturePanel {
        let panel = QuickCapturePanel()
        panel.onCancel = { [weak self] in self?.hide() }
        let hosting = NSHostingView(rootView: QuickCaptureView(
            model: model,
            shortcutTitle: settings.shortcut.title,
            onDone: { [weak self] in self?.hide() }
        ))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }

    private func position(_ panel: QuickCapturePanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.28 - size.height
        ))
    }

    // MARK: Services menu — "收进 Jelly 灵感"

    @objc func captureInspiration(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let text = pasteboard.string(forType: .URL)
            ?? pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
        diagnostics("services capture requested; types=\(pasteboard.types?.map(\.rawValue) ?? [])")
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "没有可以收下的文字或链接。" as NSString
            return
        }
        Self.log.notice("services capture requested")
        Task { @MainActor in
            do {
                _ = try await captureService.capture(text, origin: .servicesMenu)
                diagnostics("services capture saved")
            } catch {
                diagnostics("services capture failed: \(error)")
            }
        }
    }
}
