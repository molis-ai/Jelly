import SwiftUI

struct MCPServerSettingsView: View {
    let controller: MCPServiceController?
    @State private var revealToken = false

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
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 280)
            }
        }
    }

    @ViewBuilder
    private func content(controller: MCPServiceController) -> some View {
        Form {
            Section("MCP 服务器") {
                Toggle("随 Jelly 启动", isOn: enabledBinding)
                if controller.isRunning {
                    Label("运行中 · 127.0.0.1:\(controller.port?.description ?? "-")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    tokenRow(controller: controller)
                    Text("端点只监听本机回环地址，令牌写在数据目录的 mcp-server.json（仅当前用户可读）。通过 MCP 做的修改与在 App 内操作完全一致，可用 App 内的 ⌘Z 撤销。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("已停止", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                }
                if let error = controller.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if controller.isRunning {
                Section("接入 Claude Code（HTTP 直连）") {
                    commandRow(text: controller.claudeCodeCommand, label: "Claude Code 命令")
                }
                Section("接入 Claude Desktop（stdio 桥）") {
                    Text("把下面这段加进 Claude Desktop 的 claude_desktop_config.json（jelly-mcp 随 Jelly.app 一起安装）：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    commandRow(text: controller.desktopJSONConfig, label: "JSON 配置")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
    }

    @ViewBuilder
    private func tokenRow(controller: MCPServiceController) -> some View {
        HStack {
            Text(revealToken ? (controller.token ?? "") : "••••••••••••••••••••••••")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(revealToken ? "隐藏" : "显示") {
                revealToken.toggle()
            }
            Button("复制令牌") {
                copy(controller.token ?? "")
            }
        }
    }

    @ViewBuilder
    private func commandRow(text: String?, label: String) -> some View {
        HStack(alignment: .top) {
            Text(text ?? "")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer()
            Button("复制") {
                copy(text ?? "")
            }
        }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
