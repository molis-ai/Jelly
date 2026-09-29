import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("QuickCaptureTests")
@MainActor
struct QuickCaptureTests {
    @Test func submittingStoresTheThoughtAndClearsTheField() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let service = InspirationCaptureService(store: store)
        let model = QuickCaptureModel { text in
            _ = try await service.capture(text, origin: .quickCapture)
        }
        #expect(!model.canSubmit)
        model.text = "   "
        #expect(!model.canSubmit)
        model.text = "地铁上想到：周报可以只写三件事"
        #expect(await model.submit())
        #expect(model.text.isEmpty)
        #expect(model.phase == .saved)
        #expect(store.state.inspirations.values.map(\.rawText) == ["地铁上想到：周报可以只写三件事"])

        model.prepareForShow()
        #expect(model.phase == .editing)
    }

    @Test func failedSaveKeepsTheDraft() async {
        let model = QuickCaptureModel { _ in throw InspirationCaptureError.notCommitted }
        model.text = "别丢"
        #expect(!(await model.submit()))
        #expect(model.text == "别丢")
        #expect(model.phase == .failed("没有收下，内容还在。"))
    }

    @Test func settingsPersistShortcutAndSwitch() throws {
        let suite = "jelly-quick-capture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = QuickCaptureSettings(defaults: defaults)
        #expect(settings.isEnabled)
        #expect(settings.shortcut == .default)
        settings.setShortcut(QuickCaptureShortcut.presets[1])
        settings.setEnabled(false)
        let reloaded = QuickCaptureSettings(defaults: defaults)
        #expect(reloaded.shortcut.title == "⌥⌘J")
        #expect(!reloaded.isEnabled)
    }

    @Test func hotKeyRegistersAndUnregisters() {
        let hotKey = GlobalHotKey()
        let unusual = QuickCaptureShortcut(
            id: "test",
            keyCode: UInt32(kVK_F19),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            title: "test"
        )
        #expect(hotKey.register(unusual) {})
        #expect(hotKey.isRegistered)
        hotKey.unregister()
        #expect(!hotKey.isRegistered)
    }

    @Test func servicesMenuCapturesSelectedTextOrLink() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let coordinator = QuickCaptureCoordinator(captureService: InspirationCaptureService(store: store))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("jelly-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("从 Safari 选中的一句话", forType: .string)
        var error: NSString?
        coordinator.captureInspiration(pasteboard, userData: nil, error: &error)
        #expect(error == nil)
        #expect(await eventually { store.state.inspirations.count == 1 })
        #expect(store.state.inspirations.values.first?.rawText == "从 Safari 选中的一句话")

        pasteboard.clearContents()
        coordinator.captureInspiration(pasteboard, userData: nil, error: &error)
        #expect(error == "没有可以收下的文字或链接。")
        pasteboard.releaseGlobally()
    }
}

@MainActor
func eventually(
    timeout: Duration = .seconds(2),
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}
