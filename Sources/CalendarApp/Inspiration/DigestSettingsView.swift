import SwiftUI

struct DigestSettingsView: View {
    var settings: DigestSettingsStore
    let credentials: any DigestCredentialStoring
    @Environment(\.colorScheme) private var colorScheme
    @State private var sourceDraft = DigestSummarySource.service.rawValue
    @State private var serviceDraft = DigestSummaryService.minimax.rawValue
    @State private var endpointDraft = ""
    @State private var modelDraft = ""
    @State private var apiKeyDraft = ""
    @State private var status = ""
    @State private var hasSavedCredential = false
    @State private var allowCloud = false
    @State private var allowWhisper = false

    private var usesService: Bool { sourceDraft == DigestSummarySource.service.rawValue }
    private var selectedService: DigestSummaryService {
        DigestSummaryService(rawValue: serviceDraft) ?? .minimax
    }
    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        JellySettingsPage {
            JellySettingsCard {
                fieldLabel("来源")
                JellyChoicePicker(options: sourceOptions, selection: $sourceDraft)
                if usesService {
                    fieldLabel("服务")
                    JellyChoicePicker(
                        options: DigestSummaryService.allCases.map { ($0.rawValue, $0.title) },
                        selection: serviceSelection
                    )
                    if selectedService == .custom {
                        JellySettingsField(title: "HTTPS 接口地址", text: $endpointDraft)
                    }
                    JellySettingsField(title: "模型名称", text: $modelDraft)
                    JellySettingsField(
                        title: hasSavedCredential ? "新密钥" : "API 密钥",
                        text: $apiKeyDraft,
                        secure: true
                    )
                    caption("文稿会发到这个摘要接口。密钥只保存在系统钥匙串，留空不会清掉已有密钥。保存不会发测试请求。")
                    if hasSavedCredential {
                        caption("已保存密钥")
                    }
                } else {
                    caption(localRuntimeStatus)
                }
            }
            JellySettingsCard {
                sectionTitle("转写")
                if usesService, selectedService.allowsSpeechUpload {
                    Toggle("允许把音频上传到 MiniMax 转写", isOn: $allowCloud)
                        .font(.system(size: 13))
                        .toggleStyle(.switch)
                }
                Toggle("下载 Whisper 做本机转写（约 626 MB）", isOn: $allowWhisper)
                    .font(.system(size: 13))
                    .toggleStyle(.switch)
                caption("默认先用系统语音。系统没有时，首次转写会下载约 250 MB 的 SenseVoice。上传只在摘要服务是 MiniMax 时出现。")
            }
            JellySettingsCard {
                sectionTitle("灵感与拆解")
                Toggle(
                    "收下纯文本灵感后自动补一句、给几个方向",
                    isOn: Binding(
                        get: { settings.autoExpandInspirations },
                        set: { settings.setAutoExpandInspirations($0) }
                    )
                )
                .font(.system(size: 13))
                .toggleStyle(.switch)
                caption("延展、拆开并安排、观点追问和跨材料综合都用上面这个模型；选本机命令时不会改用云端。关掉后仍可在灵感详情里手动延展。")
            }
            HStack(spacing: 12) {
                Button("保存", action: save)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.elevatedSurface)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        theme.controlAccent,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                if usesService {
                    Button("删除密钥", action: deleteKey)
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.error)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(statusLooksLikeFailure ? theme.error : theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: load)
    }

    private var sourceOptions: [(id: String, title: String)] {
        [
            (DigestSummarySource.service.rawValue, "云端"),
            (LocalSummaryRuntime.codex.rawValue, "Codex"),
            (LocalSummaryRuntime.claude.rawValue, "Claude")
        ]
    }

    private var statusLooksLikeFailure: Bool {
        status.contains("失败") || status.contains("请填写") || status.contains("未能")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.primaryText)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var serviceSelection: Binding<String> {
        Binding(
            get: { serviceDraft },
            set: { newValue in
                serviceDraft = newValue
                guard let service = DigestSummaryService(rawValue: newValue), service != .custom else { return }
                endpointDraft = service.defaultEndpoint ?? ""
                modelDraft = service.defaultModel ?? ""
            }
        )
    }

    private var runtimeTitle: String {
        LocalSummaryRuntime(rawValue: sourceDraft)?.title ?? "命令"
    }

    private var localRuntimeStatus: String {
        guard let runtime = LocalSummaryRuntime(rawValue: sourceDraft) else {
            return "请选择本机命令。"
        }
        if LocalRuntimeLocator.find(runtime) == nil {
            return "还没有找到 \(runtime.title)。提炼会停下来，不会改用云端。"
        }
        return "已找到 \(runtime.title)。用本机已经登录的命令，不需要 API 密钥。"
    }

    private func load() {
        if settings.summarySource == .localRuntime {
            sourceDraft = settings.localRuntime.rawValue
        } else {
            sourceDraft = DigestSummarySource.service.rawValue
        }
        serviceDraft = settings.summaryService.rawValue
        endpointDraft = settings.endpoint
        modelDraft = settings.model
        if endpointDraft.isEmpty, let endpoint = selectedService.defaultEndpoint {
            endpointDraft = endpoint
        }
        if modelDraft.isEmpty, let model = selectedService.defaultModel {
            modelDraft = model
        }
        apiKeyDraft = ""
        hasSavedCredential = credentials.isConfigured
        allowCloud = settings.allowCloudTranscription
        allowWhisper = settings.allowLocalWhisper
    }

    private func save() {
        if usesService {
            saveService()
        } else {
            guard let runtime = LocalSummaryRuntime(rawValue: sourceDraft) else {
                status = "请选择本机命令。"
                return
            }
            settings.setSummarySource(.localRuntime)
            settings.setLocalRuntime(runtime)
            settings.setAllowLocalWhisper(allowWhisper)
            status = "已改用本机 \(runtime.title)。云端密钥没有改动。"
        }
    }

    private func saveService() {
        let service = selectedService
        let endpoint = service == .custom ? endpointDraft : (service.defaultEndpoint ?? endpointDraft)
        let model = modelDraft
        guard DigestSettingsNormalization.endpoint(endpoint) != nil,
              DigestSettingsNormalization.model(model) != nil
        else {
            status = "请填写 HTTPS 接口地址和非空模型名称。"
            return
        }
        do {
            let hasNewCredential = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasNewCredential {
                try credentials.save(apiKeyDraft)
            }
            guard settings.save(endpoint: endpoint, model: model) else {
                status = "设置未能保存。"
                return
            }
            settings.setSummarySource(.service)
            settings.setSummaryService(service)
            settings.setAllowCloudTranscription(allowCloud)
            settings.setAllowLocalWhisper(allowWhisper)
            endpointDraft = settings.endpoint
            modelDraft = settings.model
            apiKeyDraft = ""
            hasSavedCredential = credentials.isConfigured
            status = hasNewCredential ? "已保存摘要设置。" : "已保存服务和模型；密钥未改动。"
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
