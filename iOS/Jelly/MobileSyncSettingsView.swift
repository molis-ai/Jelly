import SwiftUI
import UniformTypeIdentifiers

/// Pick the same iCloud Drive folder the Mac uses (“Jelly 同步”).
struct MobileSyncSettingsView: View {
    let sync: WorkspaceSyncService
    @State private var choosing = false
    @State private var enabled = false
    @State private var folderName: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("与 Mac 同步", isOn: Binding(get: { enabled }, set: { value in
                    if value {
                        if let folder = sync.settings.folder {
                            enabled = true
                            Task { await sync.enable(folder: folder) }
                        } else {
                            choosing = true
                        }
                    } else {
                        sync.disable()
                        enabled = false
                    }
                }))
                Button(folderName == nil ? "选择同步文件夹" : "换一个文件夹", systemImage: "folder") { choosing = true }
                if let folderName {
                    LabeledContent("文件夹", value: folderName)
                }
                statusText
                if enabled {
                    Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { Task { await sync.syncNow() } }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("在“文件”里选 iCloud Drive › Jelly 同步——Mac 上 Jelly 的设置 › 同步 默认用这个文件夹。每台设备只写自己的文件；两边同时改同一篇笔记会多出一篇“（冲突副本）”，不会丢内容。")
            }
        }
        .navigationTitle("同步")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let location = SyncFolderLocation.bookmark(bookmark)
                folderName = location.displayName
                enabled = true
                message = nil
                Task { await sync.enable(folder: location) }
            } catch {
                message = "没能记住这个文件夹：\(error.localizedDescription)"
            }
        }
        .onAppear {
            enabled = sync.settings.isEnabled
            folderName = sync.settings.folder?.displayName
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch sync.status {
        case .off:
            EmptyView()
        case .idle:
            Text("等待同步…").font(.caption).foregroundStyle(.secondary)
        case .syncing:
            ProgressView("正在同步…")
        case let .synced(date, summary):
            Text("\(date.formatted(date: .omitted, time: .shortened)) \(summary)").font(.caption).foregroundStyle(.secondary)
        case let .failed(text):
            Text(text).font(.caption).foregroundStyle(.red)
        }
    }
}
