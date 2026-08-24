import SwiftUI

struct DigestSettingsView: View {
    var settings: DigestSettingsStore
    let credentials: any DigestCredentialStoring
    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var status = ""
    @State private var hasSavedCredential = false

    var body: some View {
        Form {
            Section("材料提炼") {
                TextField("HTTPS 接口地址", text: $endpointDraft)
                    .textContentType(.URL)
                TextField("模型名称", text: $modelDraft)
                SecureField("API 密钥", text: $apiKeyDraft)
                Text("字幕或本机识别生成的文稿会发送到这个摘要接口；密钥只保存在系统钥匙串。")
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
