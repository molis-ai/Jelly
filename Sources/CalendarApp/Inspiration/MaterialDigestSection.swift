import SwiftUI
import WorkspaceDomain

struct MaterialDigestClaimPresentation: Equatable {
    var text: String
    var evidenceLabels: [String]
}

enum MaterialDigestCopy {
    static func excludedContentTitle(for kind: ResolvedSourceKind) -> String {
        kind == .audio ? "广告与片头片尾" : "未纳入摘要"
    }
}

enum MaterialDigestRecoveryAction: String, Equatable, Hashable {
    case pasteText
    case chooseFile
    case retrySource

    var title: String {
        switch self {
        case .pasteText: "粘贴文字"
        case .chooseFile: "选择文件"
        case .retrySource: "重试读取"
        }
    }
}

struct MaterialDigestPresentation: Equatable {
    var isVisible: Bool
    var statusText: String
    var progressFraction: Double?
    var primaryActionTitle: String?
    var showsCancel: Bool
    var showsRetry: Bool
    var showsRefresh: Bool
    var showsOpenSettings: Bool
    var showsConfirmDownload: Bool
    var confirmDownloadTitle: String?
    var thesis: String?
    var thesisEvidenceLabels: [String]
    var takeaways: [MaterialDigestClaimPresentation]
    var chapters: [DigestChapter]
    var quotes: [DigestQuote]
    var dropped: [String]
    var droppedClaims: [MaterialDigestClaimPresentation]
    var droppedSectionTitle: String
    var coverageText: String?
    var recoveryActions: [MaterialDigestRecoveryAction]
    var materialBlocks: [MaterialBlock]
    var materialCollapsedByDefault: Bool
    var isLegacySummary: Bool
    var transcriptAvailable: Bool
    var transcriptSegments: [TranscriptSegment]
    var transcriptCollapsedByDefault: Bool

    static let hidden = MaterialDigestPresentation(
        isVisible: false,
        statusText: "",
        progressFraction: nil,
        primaryActionTitle: nil,
        showsCancel: false,
        showsRetry: false,
        showsRefresh: false,
        showsOpenSettings: false,
        showsConfirmDownload: false,
        confirmDownloadTitle: nil,
        thesis: nil,
        thesisEvidenceLabels: [],
        takeaways: [],
        chapters: [],
        quotes: [],
        dropped: [],
        droppedClaims: [],
        droppedSectionTitle: "未纳入摘要",
        coverageText: nil,
        recoveryActions: [],
        materialBlocks: [],
        materialCollapsedByDefault: true,
        isLegacySummary: false,
        transcriptAvailable: false,
        transcriptSegments: [],
        transcriptCollapsedByDefault: true
    )

    static func project(
        inspiration: Inspiration,
        digest: MaterialDigest?,
        operatorAvailable: Bool,
        modelConfigured: Bool = true,
        progressFraction: Double? = nil
    ) -> MaterialDigestPresentation {
        guard operatorAvailable,
              inspiration.supportsMaterialDigest
        else { return .hidden }

        var presentation = MaterialDigestPresentation.hidden
        presentation.isVisible = true
        presentation.progressFraction = progressFraction
        presentation.droppedSectionTitle = MaterialDigestCopy.excludedContentTitle(
            for: inspiration.resolvedSourceKind
        )
        if let result = digest?.result {
            let snapshot = digest?.preparedSnapshot
            let blocksByID = Dictionary(
                uniqueKeysWithValues: (snapshot?.blocks ?? []).map { ($0.id, $0) }
            )
            presentation.thesis = result.summary.thesis
            presentation.thesisEvidenceLabels = evidenceLabels(
                for: result.summary.thesisClaim.evidenceBlockIDs,
                blocksByID: blocksByID
            )
            presentation.takeaways = result.summary.takeawayClaims.map { claim in
                MaterialDigestClaimPresentation(
                    text: claim.text,
                    evidenceLabels: evidenceLabels(for: claim.evidenceBlockIDs, blocksByID: blocksByID)
                )
            }
            presentation.chapters = result.summary.chapters
            presentation.quotes = result.summary.quotes
            presentation.dropped = result.summary.dropped
            presentation.droppedClaims = result.summary.droppedClaims.map { claim in
                MaterialDigestClaimPresentation(
                    text: claim.text,
                    evidenceLabels: evidenceLabels(for: claim.evidenceBlockIDs, blocksByID: blocksByID)
                )
            }
            presentation.materialBlocks = snapshot?.blocks ?? []
            presentation.materialCollapsedByDefault = true
            presentation.coverageText = coverageText(for: snapshot?.coverage, isLegacy: MaterialDigestSummaryContract.isLegacy(result.provenance.summaryContractVersion))
            presentation.isLegacySummary = MaterialDigestSummaryContract.isLegacy(result.provenance.summaryContractVersion)
            presentation.transcriptAvailable = !(snapshot?.blocks.isEmpty ?? true)
            presentation.transcriptSegments = snapshot?.timestampedTranscript.segments ?? []
            presentation.transcriptCollapsedByDefault = true
        }
        if inspiration.lifecycle != .active {
            guard digest?.result != nil else { return .hidden }
            presentation.statusText = "已归档，提炼结果仅供查看。"
            return presentation
        }
        if let run = digest?.currentRun {
            presentation.showsCancel = true
            presentation.primaryActionTitle = nil
            switch run.stage {
            case .resolvingSource, .fetchingSource:
                presentation.progressFraction = nil
                presentation.statusText = "正在读取材料"
            case .extractingText:
                presentation.statusText = "正在整理文字"
            case .recognizingImages:
                presentation.statusText = "正在识别图片文字"
            case .preparingSummary:
                presentation.statusText = "材料已就绪"
            case .awaitingModelDownloadConsent:
                presentation.statusText = modelDownloadConsentText(
                    approximateBytes: digest?.currentRun?.modelDownloadApproximateBytes
                )
                presentation.showsConfirmDownload = true
                presentation.confirmDownloadTitle = "下载并继续"
            case .downloadingModel:
                presentation.progressFraction = nil
                presentation.statusText = "正在下载识别模型"
            case .transcribing:
                presentation.statusText = withProgress("正在识别音频", fraction: progressFraction)
            case .summarizing:
                presentation.statusText = "正在生成摘要"
            }
            return presentation
        }
        presentation.showsRefresh = digest?.result != nil
        if let failure = digest?.lastFailure {
            if isXiaohongshu(inspiration),
               [.restrictedSource, .sourceUnavailable, .insufficientContent]
                .contains(failure.code) {
                switch failure.code {
                case .restrictedSource:
                    presentation.statusText = "小红书限制了公开内容读取，原始链接仍然保留。"
                case .sourceUnavailable:
                    presentation.statusText = "暂时读不到这篇小红书，原始链接仍然保留。"
                case .insufficientContent:
                    presentation.statusText = "公开页面没有足够内容可提炼，原始链接仍然保留。"
                default:
                    break
                }
                presentation.recoveryActions = [.pasteText, .chooseFile, .retrySource]
                presentation.primaryActionTitle = nil
                presentation.showsRetry = false
                presentation.showsRefresh = false
                return presentation
            }
            presentation.statusText = failure.userMessage
            if failure.code == .modelNotConfigured, modelConfigured {
                presentation.statusText = "设置已就绪，可以重试提炼。"
                presentation.showsRetry = true
                presentation.primaryActionTitle = "重试"
            } else if failure.code == .modelNotConfigured
                || failure.code == .authenticationFailed
                || failure.code == .accessDenied
                || !modelConfigured {
                presentation.showsOpenSettings = true
                presentation.primaryActionTitle = "打开设置"
            } else {
                presentation.showsRetry = true
                presentation.primaryActionTitle = "重试"
            }
            return presentation
        }
        if digest?.result != nil {
            presentation.statusText = "提炼完成，可以审阅后写入笔记。"
            return presentation
        }
        if !modelConfigured {
            presentation.statusText = "可以先读取材料；生成摘要前再配置模型。"
            presentation.primaryActionTitle = "提炼这份材料"
            return presentation
        }
        presentation.statusText = "尚未提炼"
        presentation.primaryActionTitle = "提炼这份材料"
        return presentation
    }

    private static func isXiaohongshu(_ inspiration: Inspiration) -> Bool {
        guard let url = inspiration.rawURL else { return false }
        if case .xiaohongshuNote = MaterialSourceResolver.descriptorKind(for: url) { return true }
        return false
    }

    static func modelDownloadConsentText(approximateBytes: Int64?) -> String {
        let suffix = "识别模型；能公开读取字幕时不会下载。"
        guard let approximateBytes, approximateBytes > 0 else {
            return "首次需要下载\(suffix)"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        let size = formatter.string(fromByteCount: approximateBytes)
        return "首次需要下载约 \(size) \(suffix)"
    }

    private static func withProgress(_ text: String, fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return text }
        let percent = min(100, max(0, Int((fraction * 100).rounded())))
        return "\(text) \(percent)%"
    }

    private static func coverageText(for coverage: MaterialCoverage?, isLegacy: Bool) -> String? {
        if isLegacy {
            return "旧版摘要，重新提炼后可查看逐条依据"
        }
        switch coverage {
        case .partial(let processed, let expected, let issues)?:
            let countText: String
            if let expected {
                countText = "基于部分内容：\(processed)/\(expected) 项已读取"
            } else {
                countText = "基于部分内容：\(processed) 项已读取"
            }
            let issueTexts = issues.reduce(into: [String]()) { result, issue in
                let text = coverageIssueText(issue)
                if !result.contains(text) { result.append(text) }
            }
            return ([countText] + issueTexts).joined(separator: "；")
        case .sufficient?, .insufficient?, nil:
            return nil
        }
    }

    private static func coverageIssueText(_ issue: MaterialCoverageIssue) -> String {
        switch issue {
        case .inaccessibleAsset:
            return "部分内容无法访问"
        case .transcriptionFailed:
            return "部分音频未识别"
        case .ocrFailed:
            return "部分图片文字未识别"
        case .truncatedByLimit:
            return "材料过长，已提炼可读取部分"
        case .visualSemanticsUnavailable:
            return "摘要不包含视频画面含义"
        }
    }

    private static func evidenceLabels(
        for ids: [MaterialBlockID],
        blocksByID: [MaterialBlockID: MaterialBlock]
    ) -> [String] {
        ids.compactMap { blocksByID[$0]?.locator.displayLabel }
    }
}

struct MaterialDigestSection: View {
    let presentation: MaterialDigestPresentation
    var onStart: () -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onRefresh: () -> Void
    var onConfirmDownload: () -> Void
    var onPasteRecovery: () -> Void = {}
    var onChooseFileRecovery: () -> Void = {}
    @State private var transcriptExpanded = false

    var body: some View {
        if presentation.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                Text("材料提炼")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.statusText)
                    .font(.system(size: 13))
                    .accessibilityLabel(presentation.statusText)
                actionRow
                if let thesis = presentation.thesis {
                    review(thesis: thesis)
                }
            }
            .padding(.top, 16)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if let title = presentation.primaryActionTitle {
                if presentation.showsOpenSettings {
                    SettingsLink {
                        Text(title)
                    }
                    .accessibilityLabel(title)
                } else {
                    Button(title) {
                        if presentation.showsRetry { onRetry() } else { onStart() }
                    }
                    .accessibilityLabel(title)
                }
            }
            if presentation.showsConfirmDownload, let title = presentation.confirmDownloadTitle {
                Button(title, action: onConfirmDownload)
                    .accessibilityLabel(title)
            }
            if presentation.showsCancel {
                Button("取消", action: onCancel)
                    .accessibilityLabel("取消")
            }
            if presentation.showsRefresh {
                Button("重新读取来源", action: onRefresh)
                    .accessibilityLabel("重新读取来源")
            }
            ForEach(presentation.recoveryActions, id: \.self) { action in
                Button(action.title) {
                    switch action {
                    case .pasteText:
                        onPasteRecovery()
                    case .chooseFile:
                        onChooseFileRecovery()
                    case .retrySource:
                        onRefresh()
                    }
                }
                .accessibilityLabel(action.title)
            }
        }
    }

    @ViewBuilder
    private func review(thesis: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(labeled(thesis, evidenceLabels: presentation.thesisEvidenceLabels))
                .font(.system(size: 14, weight: .medium))
            if let coverage = presentation.coverageText {
                Text(coverage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(presentation.takeaways.enumerated()), id: \.offset) { _, takeaway in
                Text("• \(labeled(takeaway.text, evidenceLabels: takeaway.evidenceLabels))")
                    .font(.system(size: 13))
            }
            ForEach(Array(presentation.chapters.enumerated()), id: \.offset) { _, chapter in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(chapterLocation(chapter, presentation: presentation)) \(chapter.title)")
                        .font(.system(size: 12, weight: .medium))
                    ForEach(Array(chapter.pointClaims.enumerated()), id: \.offset) { _, point in
                        Text("• \(labeled(point.text, evidenceLabels: evidenceLabels(for: point.evidenceBlockIDs)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(presentation.quotes.enumerated()), id: \.offset) { _, quote in
                Text(quoteLine(quote))
                    .font(.system(size: 12).italic())
            }
            if !presentation.droppedClaims.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.droppedSectionTitle)
                        .font(.system(size: 12, weight: .medium))
                    ForEach(Array(presentation.droppedClaims.enumerated()), id: \.offset) { _, claim in
                        Text("• \(labeled(claim.text, evidenceLabels: claim.evidenceLabels))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if presentation.transcriptAvailable || !presentation.materialBlocks.isEmpty {
                DisclosureGroup("完整材料", isExpanded: $transcriptExpanded) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !presentation.materialBlocks.isEmpty {
                            ForEach(presentation.materialBlocks, id: \.id) { block in
                                Text("\(block.locator.displayLabel)  \(block.text)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ForEach(Array(presentation.transcriptSegments.enumerated()), id: \.offset) { _, segment in
                                Text("\(timestamp(segment.startSeconds))  \(segment.text)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
        .onAppear { transcriptExpanded = !presentation.transcriptCollapsedByDefault }
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func quoteLine(_ quote: DigestQuote) -> String {
        let prefix = "\(quoteLocation(quote, presentation: presentation)) "
        guard let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speaker.isEmpty
        else { return prefix + quote.text }
        return "\(prefix)\(speaker)：\(quote.text)"
    }

    private func chapterLocation(_ chapter: DigestChapter, presentation: MaterialDigestPresentation) -> String {
        if let id = chapter.anchorBlockID,
           let block = presentation.materialBlocks.first(where: { $0.id == id }) {
            return block.locator.displayLabel
        }
        return timestamp(chapter.startSeconds)
    }

    private func quoteLocation(_ quote: DigestQuote, presentation: MaterialDigestPresentation) -> String {
        if let id = quote.evidenceBlockID,
           let block = presentation.materialBlocks.first(where: { $0.id == id }) {
            return block.locator.displayLabel
        }
        return timestamp(quote.startSeconds)
    }

    private func evidenceLabels(for ids: [MaterialBlockID]) -> [String] {
        ids.compactMap { id in
            presentation.materialBlocks.first(where: { $0.id == id })?.locator.displayLabel
        }
    }

    private func labeled(_ text: String, evidenceLabels: [String]) -> String {
        guard !evidenceLabels.isEmpty else { return text }
        return "\(text)（\(evidenceLabels.joined(separator: "、"))）"
    }
}
