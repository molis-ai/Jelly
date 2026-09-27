import SwiftUI

struct DigestSettingsView: View {
    var settings: DigestSettingsStore
    let credentials: any DigestCredentialStoring
    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var status = ""
    @State private var hasSavedCredential = false
    @State private var allowCloud = false
    @State private var allowWhisper = false

    var body: some View {
        Form {
            Section("材料提炼") {
                TextField("HTTPS 接口地址", text: $endpointDraft)
                    .textContentType(.URL)
                TextField("模型名称", text: $modelDraft)
                SecureField("API 密钥", text: $apiKeyDraft)
                Text("字幕或转写得到的文稿会发送到这个摘要接口；密钥只保存在系统钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("内存不够时，允许把音频上传到 MiniMax 转写", isOn: $allowCloud)
                Toggle("下载 Whisper 做本机转写（约 626 MB，需要较大内存）", isOn: $allowWhisper)
                Text("默认先用系统语音。系统没有时，首次转写会下载约 250 MB 的 SenseVoice。上传和 Whisper 都要单独打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasSavedCredential {
                    Label("已保存密钥", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存") { save() }
                    Button("删除密钥", role: .destructive) { deleteKey() }
                }
                if !status.isEmpty {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
        .onAppear {
            endpointDraft = settings.endpoint
            modelDraft = settings.model
            apiKeyDraft = ""
            hasSavedCredential = credentials.isConfigured
            allowCloud = settings.allowCloudTranscription
            allowWhisper = settings.allowLocalWhisper
        }
    }

    private func save() {
        guard DigestSettingsNormalization.endpoint(endpointDraft) != nil,
              DigestSettingsNormalization.model(modelDraft) != nil
        else {
            status = "请填写 HTTPS 接口地址和非空模型名称。"
            return
        }
        do {
            let hasNewCredential = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasNewCredential {
                try credentials.save(apiKeyDraft)
            }
            guard settings.save(endpoint: endpointDraft, model: modelDraft) else {
                status = "设置未能保存。"
                return
            }
            settings.setAllowCloudTranscription(allowCloud)
            settings.setAllowLocalWhisper(allowWhisper)
            apiKeyDraft = ""
            hasSavedCredential = credentials.isConfigured
            status = hasNewCredential ? "已保存材料提炼设置。" : "已保存接口和模型；密钥未改动。"
        } catch {
            status = "密钥未能写入钥匙串，接口和模型没有改动。"
        }
    }

    private func deleteKey() {
        do {
            try credentials.delete()
            apiKeyDraft = ""
            hasSavedCredential = false
            status = "已删除密钥。摘要设置仍保留在本机。"
        } catch {
            status = "删除密钥失败。"
        }
    }
}
