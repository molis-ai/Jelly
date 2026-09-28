import SwiftUI

struct MCPServerSettingsView: View {
    let controller: MCPServiceController?
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealToken = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller?.isEnabled ?? false },
            set: { controller?.isEnabled = $0 }
        )
    }

    var body: some View {
        Group {
            if let controller {
                content(controller: controller)
            } else {
                Text("MCP 服务器在此配置下不可用。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
                    .toolbarBackground(theme.canvas, for: .windowToolbar)
            }
        }
    }

    @ViewBuilder
    private func content(controller: MCPServiceController) -> some View {
        JellySettingsPage {
            JellySettingsCard {
                Text("MCP 服务器")
                    .font(.system(size: 13, weight: .semibold))
                Toggle("随 Jelly 启动", isOn: enabledBinding)
                    .font(.system(size: 13))
                    .toggleStyle(.switch)
                if controller.isRunning {
                    Text("运行中 · 127.0.0.1:\(controller.port?.description ?? "-")")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    tokenRow(controller: controller)
                    Text("端点只监听本机回环地址，令牌写在数据目录的 mcp-server.json。通过 MCP 做的修改与在 App 内操作完全一致，可用 ⌘Z 撤销。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("已停止")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                if let error = controller.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.error)
                }
            }
            if controller.isRunning {
                JellySettingsCard {
                    Text("Claude Code")
                        .font(.system(size: 13, weight: .semibold))
                    commandRow(text: controller.claudeCodeCommand)
                }
                JellySettingsCard {
                    Text("Claude Desktop")
                        .font(.system(size: 13, weight: .semibold))
                    Text("把下面这段加进 claude_desktop_config.json。jelly-mcp 随 Jelly.app 一起安装。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    commandRow(text: controller.desktopJSONConfig)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder
    private func tokenRow(controller: MCPServiceController) -> some View {
        HStack(spacing: 10) {
            Text(revealToken ? (controller.token ?? "") : "••••••••••••••••••••••••")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            textButton(revealToken ? "隐藏" : "显示") { revealToken.toggle() }
            textButton("复制") { copy(controller.token ?? "") }
        }
    }

    @ViewBuilder
    private func commandRow(text: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.primaryText)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            textButton("复制") { copy(text ?? "") }
        }
        .padding(10)
        .background(
            theme.canvas,
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
        )
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.controlAccent)
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
