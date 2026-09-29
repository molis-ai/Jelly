import CalendarDomain
import Foundation
import SwiftUI
import WorkspaceDomain

struct MobileAISettingsView: View {
    let services: MobileAIServices
    @Environment(\.dismiss) private var dismiss
    @State private var service = DigestSummaryService.minimax.rawValue
    @State private var endpoint = ""
    @State private var model = ""
    @State private var secret = ""
    @State private var message: String?
    @State private var confirmsDelete = false
    @State private var allowCloud = false

    private var selectedService: DigestSummaryService {
        DigestSummaryService(rawValue: service) ?? .minimax
    }

    private var serviceSelection: Binding<String> {
        Binding(
            get: { service },
            set: { newValue in
                service = newValue
                guard let next = DigestSummaryService(rawValue: newValue), next != .custom else { return }
                endpoint = next.defaultEndpoint ?? ""
                model = next.defaultModel ?? ""
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务", selection: serviceSelection) {
                        ForEach(DigestSummaryService.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    if selectedService == .custom {
                        TextField("HTTPS 接口地址", text: $endpoint)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                    }
                    TextField("模型名称", text: $model).autocorrectionDisabled()
                    SecureField(services.hasSavedCredential ? "输入新密钥以替换" : "API 密钥", text: $secret)
                        .autocorrectionDisabled()
                    if services.hasSavedCredential {
                        Label("已保存密钥", systemImage: "key.fill").foregroundStyle(.secondary)
                    }
                    Button("保存设置") { save() }
                        .accessibilityIdentifier("ai-settings-save")
                    if services.hasSavedCredential {
                        Button("删除密钥", role: .destructive) { confirmsDelete = true }
                    }
                } header: {
                    Text("摘要")
                } footer: {
                    Text("点按提炼后，提取的文字会发送到这个接口。密钥保存在系统钥匙串；留空不会清除已有密钥。保存设置不会发送测试请求。")
                }
                Section("笔记拆解") {
                    switch services.planner.availability {
                    case .available:
                        Label("Apple 智能可用", systemImage: "sparkles")
                        Text("在笔记里点按智能拆开后才调用系统模型。也可以全程手动拆开和安排。")
                            .foregroundStyle(.secondary)
                    case let .unavailable(reason):
                        Text(MobileDecompositionCopy.manual(reason))
                    }
                }
                Section("音频转写") {
                    if selectedService.allowsSpeechUpload {
                        Toggle("允许把音频上传到 MiniMax 转写", isOn: $allowCloud)
                    }
                    Text("系统语音可用时优先用系统。否则首次转写会下载约 250 MB 的 SenseVoice。手机不下载 Whisper。只有摘要服务是 MiniMax 且打开开关时才会上传音频。")
                        .foregroundStyle(.secondary)
                }
                if let message { Section { Text(message).accessibilityLabel(message) } }
            }
            .navigationTitle("AI 设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                services.refreshConfiguration()
                service = services.settings.summaryService.rawValue
                endpoint = services.settings.endpoint
                model = services.settings.model
                if endpoint.isEmpty, let preset = selectedService.defaultEndpoint {
                    endpoint = preset
                }
                if model.isEmpty, let preset = selectedService.defaultModel {
                    model = preset
                }
                secret = ""
                allowCloud = services.settings.allowCloudTranscription
            }
            .confirmationDialog("删除保存的 API 密钥？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除密钥", role: .destructive) {
                    do {
                        try services.deleteCredential()
                        secret = ""
                        message = "已删除密钥。接口和模型设置仍保留。"
                    } catch { message = "钥匙串中的密钥未能删除，请重试。" }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private func save() {
        let resolvedEndpoint = selectedService == .custom
            ? endpoint
            : (selectedService.defaultEndpoint ?? endpoint)
        do {
            try services.save(
                endpoint: resolvedEndpoint,
                model: model,
                newSecret: secret,
                service: selectedService
            )
            services.settings.setAllowCloudTranscription(allowCloud)
            secret = ""
            endpoint = services.settings.endpoint
            model = services.settings.model
            message = services.isConfigured ? "设置已保存。" : "接口和模型已保存；添加密钥后可生成摘要。"
        } catch MobileAIConfigurationError.invalidSettings {
            message = "请填写有效的 HTTPS 接口地址和模型名称。"
        } catch {
            message = "密钥未能写入系统钥匙串，接口和模型没有改动。"
        }
    }
}

/// Embedded in an inspiration detail. Writing the reviewed result to a note
/// remains the detail's existing InspirationViewModel.convertSelectedToNote().
struct MobileDigestSection: View {
    let workspace: MobileWorkspace
    let inspirationID: InspirationID
    var onPasteRecovery: (() -> Void)? = nil
    var onChooseFileRecovery: (() -> Void)? = nil
    @State private var showingSettings = false
    @State private var confirmsModelDownload = false
    @State private var admittingRequest = false
    @State private var requestMessage: String?

    private var presentation: MaterialDigestPresentation {
        guard let inspiration = workspace.state.inspirations[inspirationID] else { return .hidden }
        return .project(
            inspiration: inspiration,
            digest: workspace.state.materialDigests[inspirationID],
            operatorAvailable: true,
            modelConfigured: workspace.ai.isConfigured,
            progressFraction: workspace.ai.digest.progress(for: inspirationID)
        )
    }

    var body: some View {
        let value = presentation
        if value.isVisible {
            VStack(alignment: .leading, spacing: 14) {
                Label("材料提炼", systemImage: "sparkles").font(.headline)
                Text(value.statusText).foregroundStyle(.secondary)
                if let progress = value.progressFraction {
                    ProgressView(value: min(1, max(0, progress))).accessibilityLabel(value.statusText)
                } else if value.showsCancel && !value.showsConfirmDownload {
                    ProgressView().accessibilityLabel(value.statusText)
                }
                actions(value)
                if let requestMessage { Text(requestMessage).foregroundStyle(.secondary) }
                if value.primaryActionTitle != nil && !value.showsOpenSettings {
                    Text("提炼会读取这份材料，并把文字发送到你设置的摘要接口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let thesis = value.thesis { review(value, thesis: thesis) }
            }
            .sheet(isPresented: $showingSettings) { MobileAISettingsView(services: workspace.ai) }
            .confirmationDialog("下载本地识别模型？", isPresented: $confirmsModelDownload, titleVisibility: .visible) {
                Button("下载并继续") { run { await workspace.ai.digest.confirmModelDownload(inspirationID: inspirationID) } }
                Button("暂不下载", role: .cancel) { }
            } message: {
                Text(MaterialDigestPresentation.modelDownloadConsentText(
                    approximateBytes: workspace.state.materialDigests[inspirationID]?.currentRun?.modelDownloadApproximateBytes
                ))
            }
        }
    }

    @ViewBuilder private func actions(_ value: MaterialDigestPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = value.primaryActionTitle {
                Button(title) {
                    if value.showsOpenSettings { showingSettings = true }
                    else { run { await workspace.ai.digest.start(inspirationID: inspirationID) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(admittingRequest || (!workspace.isReady && !value.showsOpenSettings))
            }
            if value.showsConfirmDownload {
                Button(value.confirmDownloadTitle ?? "下载并继续") { confirmsModelDownload = true }
                    .buttonStyle(.borderedProminent).disabled(!workspace.isReady || admittingRequest)
            }
            if value.showsCancel {
                Button("取消提炼", role: .cancel) { run { await workspace.ai.digest.cancel(inspirationID: inspirationID) } }
                    .disabled(admittingRequest)
            }
            if value.showsRefresh {
                Button("重新读取来源") { refresh() }.disabled(!workspace.isReady || admittingRequest)
            }
            ForEach(value.recoveryActions, id: \.self) { action in
                switch action {
                case .retrySource:
                    Button(action.title) { refresh() }.disabled(!workspace.isReady || admittingRequest)
                case .pasteText:
                    if let onPasteRecovery { Button(action.title, action: onPasteRecovery) }
                case .chooseFile:
                    if let onChooseFileRecovery { Button(action.title, action: onChooseFileRecovery) }
                }
            }
            if !value.recoveryActions.isEmpty && onPasteRecovery == nil && onChooseFileRecovery == nil {
                Text("也可以回到灵感页，新增已保存的文字、截图或材料文件。原始链接会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !admittingRequest else { return }
        admittingRequest = true
        requestMessage = nil
        Task { @MainActor in
            await operation()
            admittingRequest = false
            if !workspace.isReady {
                requestMessage = "工作空间正在等待保存或恢复，请先处理顶部提示。"
            }
        }
    }

    private func refresh() {
        run { await workspace.ai.digest.start(inspirationID: inspirationID, mode: .refreshSource) }
    }

    private func review(_ value: MaterialDigestPresentation, thesis: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("核心观点").font(.headline)
            claim(thesis, labels: value.thesisEvidenceLabels)
            if let coverage = value.coverageText {
                Label(coverage, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(value.takeaways.enumerated()), id: \.offset) { _, item in
                claim("• \(item.text)", labels: item.evidenceLabels)
            }
            ForEach(Array(value.chapters.enumerated()), id: \.offset) { _, chapter in
                DisclosureGroup(chapter.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(chapter.pointClaims.enumerated()), id: \.offset) { _, item in
                            claim(item.text, labels: labels(item.evidenceBlockIDs, in: value))
                        }
                    }.padding(.top, 8)
                }
            }
            if !value.quotes.isEmpty {
                Text("引用").font(.headline)
                ForEach(Array(value.quotes.enumerated()), id: \.offset) { _, quote in
                    claim((quote.speaker.map { "\($0)：" } ?? "") + quote.text,
                          labels: labels(quote.evidenceBlockID.map { [$0] } ?? [], in: value))
                }
            }
            if !value.droppedClaims.isEmpty {
                DisclosureGroup(value.droppedSectionTitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(value.droppedClaims.enumerated()), id: \.offset) { _, item in
                            claim(item.text, labels: item.evidenceLabels)
                        }
                    }.padding(.top, 8)
                }
            }
            if !value.materialBlocks.isEmpty {
                DisclosureGroup("查看完整材料与依据") {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(value.materialBlocks) { block in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.locator.displayLabel).font(.caption).foregroundStyle(.secondary)
                                Text(block.text).textSelection(.enabled)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
            if let result = workspace.state.materialDigests[inspirationID]?.result {
                Text("\(result.provenance.modelIdentifier) · \(result.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func claim(_ text: String, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).textSelection(.enabled)
            if !labels.isEmpty { Text(labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func labels(_ ids: [MaterialBlockID], in value: MaterialDigestPresentation) -> [String] {
        ids.compactMap { id in value.materialBlocks.first { $0.id == id }?.locator.displayLabel }
    }
}

struct MobileDecompositionView: View {
    let workspace: MobileWorkspace
    let noteID: NoteID
    var selection: BlockEditorSelection? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var model: DecompositionWorkbenchModel?
    @State private var sourceError: String?
    @State private var choseManual = false
    @State private var confirmsDiscard = false
    @State private var commitMessage: String?
    @State private var committedGeneration: UInt?
    @State private var hasCommitted = false
    @State private var isUndoing = false

    var body: some View {
        NavigationStack {
            Group {
                if let model { workbench(model) }
                else if let sourceError {
                    ContentUnavailableView("暂时不能拆开", systemImage: "doc.text.magnifyingglass", description: Text(sourceError))
                } else { ProgressView("正在准备笔记…") }
            }
            .navigationTitle("拆开并安排")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasCommitted ? "完成" : "关闭") { requestDismiss() }
                        .disabled(model?.isCommitting == true || isUndoing)
                }
            }
            .interactiveDismissDisabled(model?.isCommitting == true || (model?.hasMeaningfulDraft == true && !hasCommitted))
            .confirmationDialog("放弃这次拆解？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("放弃并关闭", role: .destructive) { model?.cancelRequest(); dismiss() }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("候选行动还没有写入笔记或日历，关闭后不会保留这次草稿。") }
            .task { prepare() }
            .onDisappear { model?.cancelRequest() }
        }
    }

    private func prepare() {
        guard model == nil else { return }
        guard workspace.isReady else { sourceError = "请先完成工作空间的保存或恢复。"; return }
        guard let note = workspace.state.notes[noteID], let first = note.document.blocks.first else {
            sourceError = "笔记还没有可拆解的内容。"; return
        }
        do {
            let caret = BlockTextPosition(blockID: first.id, graphemeOffset: 0)
            let snapshot = try DecompositionSourceCapture.capture(
                note: note, workspaceRevision: workspace.state.revision,
                selection: selection ?? .text(anchor: caret, focus: caret, preferredColumn: nil,
                                 typingAttributes: .init(marks: [], linkURL: nil))
            )
            let value = DecompositionWorkbenchModel(snapshot: snapshot, planner: workspace.ai.planner, store: workspace.store)
            if case let .unavailable(reason) = workspace.ai.planner.availability { value.enterManualMode(reason: reason) }
            model = value
        } catch { sourceError = "笔记中没有可用的正文，请先保存一些文字。" }
    }

    private func workbench(_ model: DecompositionWorkbenchModel) -> some View {
        Form {
            Section {
                DisclosureGroup("原始笔记") { Text(model.draft.source.normalizedText).textSelection(.enabled) }
                if choseManual { Text("手动拆开：填写行动和完成标准，再决定是否加入日历。").foregroundStyle(.secondary) }
                else if case let .manual(reason) = model.draft.mode { Text(MobileDecompositionCopy.manual(reason)).foregroundStyle(.secondary) }
                if let error = model.draft.lastRecoverableError { Text(MobileDecompositionCopy.recoverable(error)).foregroundStyle(.secondary) }
            }
            if !hasCommitted {
                if model.hasRunningRequest {
                    Section {
                        ProgressView("正在整理候选行动…")
                        Button("取消这次请求", role: .cancel) { model.cancelRequest() }
                    }
                }
                if model.draft.stage == .understand { understanding(model) }
                else {
                    candidates(model)
                    controls(model)
                }
            }
            if let commitMessage {
                Section {
                    Label(commitMessage, systemImage: hasCommitted ? "checkmark.circle" : "info.circle")
                    if canUndoGroup {
                        Button("撤销这整组行动和安排") { undoGroup() }.disabled(isUndoing)
                    }
                }
            }
        }
        .disabled(model.isCommitting)
        .overlay { if model.isCommitting { ProgressView("正在一起保存行动和日历…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
    }

    private func understanding(_ model: DecompositionWorkbenchModel) -> some View {
        Section("理解目标") {
            if let question = model.draft.question {
                Text(question.text)
                TextField("你的补充", text: Binding(get: { model.draft.answer }, set: model.updateAnswer), axis: .vertical)
                ForEach(question.quickAnswers, id: \.self) { answer in
                    Button(answer) { Task { await model.submitAnswer(answer) } }.disabled(model.hasRunningRequest)
                }
                Button("生成候选行动") { Task { await model.submitAnswer(model.draft.answer) } }
                    .disabled(model.draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.hasRunningRequest)
            } else {
                Text("先整理成可执行的行动，审阅后再一次性写入。")
                Button("使用 Apple 智能拆开") { Task { await model.start() } }
                    .disabled(model.hasRunningRequest)
            }
            Button("我来手动拆开") { choseManual = true; model.addManualCandidate() }
        }
    }

    private func candidates(_ model: DecompositionWorkbenchModel) -> some View {
        Section(model.draft.stage == .schedule ? "确认行动与日历" : "编辑候选行动") {
            ForEach(model.draft.candidates) { candidate in
                candidateEditor(candidate, model: model)
            }
            Button("添加行动", systemImage: "plus") { model.addManualCandidate() }
            if !choseManual, case .intelligent = model.draft.mode {
                Button("重新整理未锁定的内容") { Task { await model.refreshUnlockedCandidates() } }
                    .disabled(model.hasRunningRequest || model.draft.candidates.isEmpty)
                Text("你手动改过的标题和完成标准会保留。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func candidateEditor(_ candidate: CandidateAction, model: DecompositionWorkbenchModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("创建这个行动", isOn: Binding(get: { candidate.selectedForCreation }, set: { model.setSelectedForCreation(id: candidate.id, selected: $0) }))
            TextField("行动名称", text: Binding(get: { candidate.title }, set: { model.updateTitle(id: candidate.id, value: $0) }), axis: .vertical)
                .font(.headline)
            TextField("怎样算完成？", text: Binding(get: { candidate.completionDescription }, set: { model.updateCompletion(id: candidate.id, value: $0) }), axis: .vertical)
            Picker("预计时长", selection: Binding(get: { candidate.estimatedDuration }, set: { model.updateDuration(id: candidate.id, duration: $0) })) {
                ForEach(CandidateDuration.allCases, id: \.rawValue) { duration in Text("\(duration.rawValue) 分钟").tag(duration) }
            }
            Toggle("加入日历", isOn: Binding(get: { candidate.selectedForCalendar }, set: { model.setSelectedForCalendar(id: candidate.id, selected: $0) }))
                .disabled(!candidate.selectedForCreation)
            if model.draft.stage == .schedule && candidate.selectedForCreation && candidate.selectedForCalendar {
                if candidate.proposal != nil {
                    DatePicker("日期", selection: Binding(get: { model.editorInstant(id: candidate.id) }, set: { model.updateProposalDate(id: candidate.id, instant: $0) }), displayedComponents: .date)
                    DatePicker("开始时间", selection: Binding(get: { model.editorInstant(id: candidate.id) }, set: { model.updateProposalTime(id: candidate.id, instant: $0) }), displayedComponents: .hourAndMinute)
                } else {
                    Text("没有找到合适的空档，请手动选时间或取消加入日历。").font(.caption).foregroundStyle(.secondary)
                    Button("手动选时间") { model.beginManualCalendarProposal(id: candidate.id) }
                }
            }
            HStack {
                Menu("更多", systemImage: "ellipsis.circle") {
                    if !choseManual, case .intelligent = model.draft.mode {
                        Button("继续拆小") { Task { await model.split(candidate.id) } }.disabled(model.hasRunningRequest)
                    }
                    if let index = model.draft.candidates.firstIndex(where: { $0.id == candidate.id }) {
                        if index > 0 { Button("上移") { model.moveCandidate(id: candidate.id, toPositionOf: model.draft.candidates[index - 1].id) } }
                        if index + 1 < model.draft.candidates.count { Button("下移") { model.moveCandidate(id: candidate.id, toPositionOf: model.draft.candidates[index + 1].id) } }
                    }
                    Button("删除行动", role: .destructive) { model.deleteCandidate(id: candidate.id) }
                }
                Spacer()
                if candidate.titleLockedByUser || candidate.completionLockedByUser {
                    Label("已保留你的修改", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8)
    }

    private func controls(_ model: DecompositionWorkbenchModel) -> some View {
        Section {
            let selected = model.draft.candidates.filter(\.selectedForCreation)
            Text("创建 \(selected.count) 个行动，其中 \(selected.filter(\.selectedForCalendar).count) 个加入日历。")
            if model.draft.stage == .schedule {
                if let reason = model.commitBlockingReason { Text(MobileDecompositionCopy.blocking(reason)).foregroundStyle(.secondary) }
                Button("重新寻找空档") { model.refreshCalendarProposals() }
                Text("手动调整过的安排会保留。").font(.caption).foregroundStyle(.secondary)
                Button("确认并一起保存") { commit(model) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCommit || !workspace.isReady || model.hasRunningRequest)
                Button("返回编辑行动") { model.returnToStage(.split) }
            } else {
                if let reason = model.advanceBlockingReason { Text(MobileDecompositionCopy.blocking(reason)).foregroundStyle(.secondary) }
                Button("下一步：确认日历") { model.advanceToSchedule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canAdvance || model.hasRunningRequest)
            }
        } footer: { Text("确认前不会改变笔记或日历；保存后可以整组撤销。") }
    }

    private func commit(_ model: DecompositionWorkbenchModel) {
        commitMessage = nil
        Task { @MainActor in
            switch await model.commit() {
            case let .committed(created, scheduled, generation):
                committedGeneration = generation
                hasCommitted = true
                commitMessage = "已创建 \(created) 个行动，\(scheduled) 个已加入日历。"
            case .sourceChanged: commitMessage = "笔记已经改变。请关闭并确认最新内容后重新拆开。"
            case .calendarConflict: commitMessage = "日历出现时间冲突，请调整安排后重试。"
            case let .notCommitted(message): commitMessage = message
            }
        }
    }

    private var canUndoGroup: Bool {
        hasCommitted && committedGeneration == workspace.store.statePublicationGeneration
            && workspace.store.latestUndoLabel == "拆开并安排" && workspace.canUndo
    }

    private func undoGroup() {
        guard canUndoGroup else { return }
        isUndoing = true
        Task { @MainActor in
            if await workspace.undo() {
                committedGeneration = nil
                commitMessage = "已撤销这整组行动和日历安排。"
            } else { commitMessage = workspace.errorMessage ?? "尚未完成撤销，请检查工作空间的恢复提示。" }
            isUndoing = false
        }
    }

    private func requestDismiss() {
        guard model?.isCommitting != true, !isUndoing else { return }
        if model?.hasMeaningfulDraft == true && !hasCommitted { confirmsDiscard = true }
        else { model?.cancelRequest(); dismiss() }
    }
}

private enum MobileDecompositionCopy {
    static func manual(_ reason: ManualDecompositionReason) -> String {
        let explanation: String = switch reason {
        case .systemVersionUnsupported: "当前系统版本不支持 Apple 智能拆解"
        case .deviceNotEligible: "这台设备不支持 Apple 智能拆解"
        case .appleIntelligenceNotEnabled: "尚未开启 Apple 智能"
        case .modelNotReady: "系统模型还没有准备好"
        case .localeUnsupported: "系统模型暂不支持当前语言"
        case .timedOut: "这次智能整理超时了"
        case .repeatedInvalidOutput: "这次智能整理的结果没有通过校验"
        case .modelFailure: "这次智能整理没有完成"
        }
        return explanation + "。仍可手动添加行动、填写完成标准并安排日历。"
    }

    static func blocking(_ reason: DecompositionWorkbenchBlockingReason) -> String {
        switch reason {
        case .sourceChanged: "笔记已改变，请关闭并重新打开拆解。"
        case .noSelectedActions: "请至少选择一个要创建的行动。"
        case let .missingTitle(count): "还有 \(count) 个行动没有名称。"
        case let .missingCompletion(count): "还有 \(count) 个行动没有完成标准。"
        case let .missingCalendarProposal(count): "还有 \(count) 个行动没有安排时间。"
        }
    }

    static func recoverable(_ error: DecompositionRecoverableError) -> String {
        switch error {
        case .requestCancelled: "已取消请求，已有候选行动保留。"
        case .planningFailed: "整理没有完成，可以重试或继续手动编辑。"
        case .sourceChanged: "原笔记已发生变化，请先确认最新内容。"
        case .calendarConflict: "安排存在冲突，请调整日期、时间或取消加入日历。"
        case .persistenceFailed: "尚未完成写入，请保留当前草稿并处理恢复提示。"
        }
    }
}
