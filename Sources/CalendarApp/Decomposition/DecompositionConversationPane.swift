import SwiftUI

struct DecompositionConversationPane: View {
    @Bindable var model: DecompositionWorkbenchModel
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(DecompositionWorkbenchCopy.source)
                    .font(DecompositionTypography.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                Text(model.draft.source.normalizedText)
                    .font(DecompositionTypography.auxiliary)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)

                if case .manual(let reason) = model.draft.mode {
                    let banner = DecompositionWorkbenchCopy.manualBanner(for: reason)
                    DecompositionAccessibleLabel(
                        text: banner,
                        identifier: "decomposition-manual-banner",
                        label: banner
                    )
                }

                if case .running = model.requestState {
                    HStack(spacing: 10) {
                        DecompositionAccessibleLabel(
                            text: DecompositionWorkbenchCopy.organizing,
                            identifier: "decomposition-organizing",
                            label: DecompositionWorkbenchCopy.organizing
                        )
                        DecompositionIdentifiedButton(
                            title: DecompositionWorkbenchCopy.stop,
                            identifier: "decomposition-stop",
                            accessibilityName: DecompositionWorkbenchCopy.stop,
                            helpText: DecompositionWorkbenchCopy.stopHelp,
                            enabled: !model.isCommitting
                        ) {
                            model.cancelRequest()
                        }
                        .frame(width: 44, height: 22)
                    }
                }

                if let question = model.draft.question, model.draft.stage == .understand {
                    Text(question.text)
                        .font(DecompositionTypography.body)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        DecompositionIdentifiedTextField(
                            text: answerBinding,
                            identifier: "decomposition-answer",
                            accessibilityName: "回答",
                            placeholder: "用一句话回答",
                            onSubmit: { submitAnswer() }
                        )
                        .frame(height: 24)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.separator).frame(height: 1)
                        }
                        .disabled(model.isCommitting)
                        DecompositionIdentifiedButton(
                            title: DecompositionWorkbenchCopy.continueAnswer,
                            identifier: "decomposition-answer-continue",
                            accessibilityName: DecompositionWorkbenchCopy.continueAnswer,
                            enabled: canSubmitAnswer,
                            isBordered: true
                        ) {
                            submitAnswer()
                        }
                        .frame(width: 52, height: 24)
                    }
                    HStack(spacing: 10) {
                        ForEach(question.quickAnswers.prefix(3), id: \.self) { answer in
                            Button(answer) {
                                Task {
                                    model.updateAnswer(answer)
                                    await model.submitAnswer(answer)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(DecompositionTypography.auxiliary)
                            .foregroundStyle(theme.controlAccent)
                            .disabled(model.isCommitting)
                            .accessibilityLabel(answer)
                        }
                    }
                }

                if model.draft.stage == .split, !isManual {
                    Button("按最新回答重新建议") {
                        Task { await model.refreshUnlockedCandidates() }
                    }
                    .buttonStyle(.plain)
                    .font(DecompositionTypography.auxiliary)
                    .foregroundStyle(theme.controlAccent)
                    .disabled(model.isCommitting || model.draft.candidates.isEmpty)
                    .help("只更新尚未改过的行动，已改的标题和完成说明会保留")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(!model.isCommitting)
    }

    private var isManual: Bool {
        if case .manual = model.draft.mode { return true }
        return false
    }

    private var canSubmitAnswer: Bool {
        !model.draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.hasRunningRequest
            && !model.isCommitting
    }

    private func submitAnswer() {
        guard canSubmitAnswer else { return }
        Task { await model.submitAnswer(model.draft.answer) }
    }

    private var answerBinding: Binding<String> {
        Binding(
            get: { model.draft.answer },
            set: { model.updateAnswer($0) }
        )
    }
}
