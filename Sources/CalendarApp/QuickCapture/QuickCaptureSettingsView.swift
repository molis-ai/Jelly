import WorkspaceDomain
import SwiftUI

struct QuickCaptureSettingsView: View {
    let coordinator: QuickCaptureCoordinator?
    @State private var shortcutID = QuickCaptureShortcut.default.id
    @State private var enabled = true
    @State private var status = ""
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        JellySettingsPage {
            JellySettingsCard {
                Text("随手记")
                    .font(.system(size: 13, weight: .semibold))
                Toggle("在任何 App 里按快捷键弹出小窗", isOn: $enabled)
                    .font(.system(size: 13))
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, value in apply(enabled: value) }
                JellyChoicePicker(
                    options: QuickCaptureShortcut.presets.map { ($0.id, $0.title) },
                    selection: Binding(
                        get: { shortcutID },
                        set: { id in
                            shortcutID = id
                            apply(enabled: enabled)
                        }
                    )
                )
                .disabled(!enabled)
                caption("回车收下，小窗自己收起，不会切到 Jelly。收下的内容和在灵感页里记的一样，链接会自动取标题。")
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(status.contains("占用") ? theme.error : theme.secondaryText)
                }
            }
            JellySettingsCard {
                Text("从别的 App 丢进来")
                    .font(.system(size: 13, weight: .semibold))
                caption("选中文字或链接后，右键 › 服务 › 收进 Jelly 灵感。第一次使用时，如果菜单里没有它，可在系统设置 › 键盘 › 键盘快捷键 › 服务 里勾选。")
                caption("菜单栏的灯泡图标里也能随手记、开始回顾。")
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear(perform: load)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        guard let coordinator else { return }
        enabled = coordinator.settings.isEnabled
        shortcutID = coordinator.settings.shortcut.id
        status = coordinator.registrationFailed ? "这个组合被别的 App 占用了，换一个试试。" : ""
    }

    private func apply(enabled: Bool) {
        guard let coordinator,
              let shortcut = QuickCaptureShortcut.preset(id: shortcutID)
        else { return }
        coordinator.settings.setEnabled(enabled)
        coordinator.settings.setShortcut(shortcut)
        coordinator.applySettings()
        if !enabled {
            status = "已关闭快捷键。"
        } else if coordinator.registrationFailed {
            status = "\(shortcut.title) 被别的 App 占用了，换一个试试。"
        } else {
            status = "现在按 \(shortcut.title) 随手记。"
        }
    }
}

/// Menu bar lightbulb: capture, review, open.
struct JellyMenuBarContent: View {
    let store: WorkspaceStore
    let quickCapture: QuickCaptureCoordinator
    let followUp: InspirationFollowUpService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("随手记一条…  \(quickCapture.settings.shortcut.title)") {
            quickCapture.show()
        }
        let due = InspirationReviewQueue.due(in: store.state, now: Date()).count
        Button(due > 0 ? "回顾 \(due) 条旧灵感" : "没有待回顾的灵感") {
            openMainWindow()
            followUp.isReviewPresented = true
        }
        .disabled(due == 0)
        Divider()
        Button("打开 Jelly") { openMainWindow() }
    }

    private func openMainWindow() {
        openWindow(id: "main-calendar")
        NSApplication.shared.activate()
    }
}
