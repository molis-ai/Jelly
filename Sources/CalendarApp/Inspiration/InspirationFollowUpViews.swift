import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// "补一句 + 2–3 个方向", shown under the raw thought. The raw text above it is
/// never touched; each direction is adopted or ignored on its own.
struct InspirationExpansionSection: View {
    let inspiration: Inspiration
    let followUp: InspirationFollowUpService
    var onScheduleDirection: (ExpansionDirection) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var isRunning: Bool { followUp.runningExpansions.contains(inspiration.id) }

    private var isStale: Bool {
        guard let expansion = inspiration.expansion else { return false }
        return expansion.sourceChecksum != WorkspaceChecksum.inspirationSourceChecksum(inspiration)
    }

    var body: some View {
        if followUp.canExpand(inspiration) || inspiration.expansion != nil {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                    .overlay(theme.separator.opacity(0.7))
                    .padding(.vertical, 20)
                HStack(alignment: .firstTextBaseline) {
                    Text("延展")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    if let model = inspiration.expansion?.modelIdentifier {
                        Text(model)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                    Spacer(minLength: 12)
                    trailingAction
                }
                if isRunning {
                    Label("正在补一句…", systemImage: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                } else if let expansion = inspiration.expansion {
                    if isStale {
                        Label("原文改过了，这些延展基于旧版本。", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Text(expansion.supplement)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(expansion.directions) { direction in
                            directionRow(direction)
                        }
                    }
                } else if !followUp.isModelConfigured {
                    Text("在设置 › 摘要里选好模型后，收下的想法会自动补一句、给几个方向。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                if let message = followUp.messages[inspiration.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspiration-expansion")
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if !isRunning, followUp.isModelConfigured, followUp.canExpand(inspiration) {
            Button(inspiration.expansion == nil ? "延展" : "重新延展") {
                followUp.startExpansion(inspiration.id)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .accessibilityIdentifier("inspiration-expand")
        }
    }

    private func directionRow(_ direction: ExpansionDirection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(for: direction.decision))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(direction.decision == .adopted ? theme.controlAccent : theme.secondaryText)
                .frame(width: 14)
            Text(direction.text)
                .font(.system(size: 13))
                .foregroundStyle(direction.decision == .ignored ? theme.secondaryText : theme.primaryText)
                .strikethrough(direction.decision == .ignored, color: theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch direction.decision {
            case .pending:
                Button("采纳") { decide(direction, .adopted) }
                    .accessibilityLabel("采纳：\(direction.text)")
                Button("忽略") { decide(direction, .ignored) }
                    .accessibilityLabel("忽略：\(direction.text)")
            case .adopted:
                Button("变成待办") { onScheduleDirection(direction) }
                Button("撤回") { decide(direction, .pending) }
            case .ignored:
                Button("撤回") { decide(direction, .pending) }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(direction.decision == .adopted
                    ? theme.controlAccent.opacity(0.09)
                    : theme.elevatedSurface.opacity(0.35))
        )
    }

    private func symbol(for decision: ExpansionDirectionDecision) -> String {
        switch decision {
        case .pending: "arrow.turn.down.right"
        case .adopted: "checkmark"
        case .ignored: "minus"
        }
    }

    private func decide(_ direction: ExpansionDirection, _ decision: ExpansionDirectionDecision) {
        Task { await followUp.decide(inspiration.id, directionID: direction.id, decision: decision) }
    }
}

/// "你怎么看" under a finished digest: optional AI questions, the user's answer.
struct InspirationPerspectiveSection: View {
    let inspiration: Inspiration
    let title: String
    let followUp: InspirationFollowUpService
    @State private var draft = ""
    @State private var saved = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var perspective: InspirationPerspective? { inspiration.perspective }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .overlay(theme.separator.opacity(0.7))
                .padding(.vertical, 20)
            HStack(alignment: .firstTextBaseline) {
                Text("我的看法")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 12)
                if followUp.runningPerspectives.contains(inspiration.id) {
                    ProgressView().controlSize(.small)
                } else if followUp.isModelConfigured {
                    Button((perspective?.questions.isEmpty ?? true) ? "追问我" : "换几个问题") {
                        Task { await followUp.askPerspectiveQuestions(inspiration.id, title: title) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                }
            }
            ForEach(Array((perspective?.questions ?? []).enumerated()), id: \.offset) { _, question in
                Label(question, systemImage: "questionmark.bubble")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
            }
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 160)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.elevatedSurface.opacity(0.35))
                )
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("同意吗？和你的经历有什么冲突？打算怎么用？")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("我的看法")
            HStack {
                Button("保存看法") {
                    Task {
                        saved = await followUp.saveAnswer(inspiration.id, answer: draft)
                    }
                }
                .disabled(draft == (perspective?.answer ?? ""))
                if saved, draft == (perspective?.answer ?? "") {
                    Text("已保存，转成笔记时会一起带上。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            if let message = followUp.messages[inspiration.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { draft = perspective?.answer ?? "" }
        .onChange(of: inspiration.id) { _, _ in
            draft = perspective?.answer ?? ""
            saved = false
        }
        .accessibilityIdentifier("inspiration-perspective")
    }
}

/// "安排" menu: today, tomorrow, a picked day, or the undated list.
struct InspirationScheduleMenu: View {
    var title = "安排"
    let onSchedule: (InspirationScheduleChoice) -> Void
    @State private var pickingDate = false
    @State private var pickedDate = Date()

    var body: some View {
        Menu {
            Button("今天") { onSchedule(.today) }
            Button("明天") { onSchedule(.tomorrow) }
            Button("选一天…") { pickingDate = true }
            Divider()
            Button("放进无日期清单") { onSchedule(.undated) }
        } label: {
            Label(title, systemImage: "calendar.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $pickingDate) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("日期", selection: $pickedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Spacer()
                    Button("取消") { pickingDate = false }
                    Button("安排") {
                        pickingDate = false
                        onSchedule(.day(CalendarDate.today(now: pickedDate)))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
        .accessibilityIdentifier("inspiration-schedule-menu")
    }
}
