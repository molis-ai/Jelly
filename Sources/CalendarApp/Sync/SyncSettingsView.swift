import AppKit
import SwiftUI

struct SyncSettingsView: View {
    let service: WorkspaceSyncService
    @State private var enabled = false
    @State private var folder: SyncFolderLocation?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        JellySettingsPage {
            JellySettingsCard {
                Text("Mac 与 iPhone 同步")
                    .font(.system(size: 13, weight: .semibold))
                Toggle("通过共享文件夹同步日历、笔记、灵感和清单", isOn: Binding(
                    get: { enabled },
                    set: { value in toggle(value) }
                ))
                .font(.system(size: 13))
                .toggleStyle(.switch)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(theme.secondaryText)
                    Text(folder?.displayName ?? "还没有选文件夹")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…", action: chooseFolder)
                }
                caption("默认放在 iCloud Drive 的“Jelly 同步”文件夹。在 iPhone 的 Jelly › 设置 › 同步 里选同一个文件夹即可。每台设备只写自己的文件，iCloud 不会产生冲突副本；两边同时改同一篇笔记时，会多出一篇“（冲突副本）”，不会丢内容。")
                statusLine
                if enabled {
                    HStack {
                        Button("立即同步") { Task { await service.syncNow() } }
                        if !service.peerNames.isEmpty {
                            Text("已发现：\(service.peerNames.joined(separator: "、"))")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
            JellySettingsCard {
                Text("不会同步的")
                    .font(.system(size: 13, weight: .semibold))
                caption("摘要设置和密钥、快捷键、提醒事项权限各台设备分开设置。同步一次会作为一步撤销，“编辑 › 撤销”可以回到同步前。")
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            enabled = service.settings.isEnabled
            folder = service.settings.folder
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch service.status {
        case .off:
            EmptyView()
        case .idle:
            Text("等待同步…").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
        case .syncing:
            Text("正在同步…").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
        case let .synced(date, summary):
            Text("\(date.formatted(date: .omitted, time: .shortened)) \(summary)")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        case let .failed(message):
            Text(message).font(.system(size: 12)).foregroundStyle(theme.error)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ value: Bool) {
        if value {
            let location = folder ?? .path(SyncSettings.defaultMacFolder.path)
            if case let .path(path) = location {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            folder = location
            enabled = true
            Task { await service.enable(folder: location) }
        } else {
            service.disable()
            enabled = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "用这个文件夹同步"
        if SyncSettings.iCloudDriveAvailable {
            panel.directoryURL = SyncSettings.defaultMacFolder.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let location = SyncFolderLocation.path(url.path)
        folder = location
        service.settings.folder = location
        if enabled { Task { await service.syncNow() } }
    }
}
