import SwiftUI
import WorkspaceDomain

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
