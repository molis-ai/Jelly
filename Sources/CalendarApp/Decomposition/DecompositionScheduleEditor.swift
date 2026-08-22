import CalendarDomain
import SwiftUI

struct DecompositionScheduleEditor: View {
    @Bindable var model: DecompositionWorkbenchModel
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var scheduledCandidates: [CandidateAction] {
        model.draft.candidates.filter(\.selectedForCreation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(DecompositionWorkbenchCopy.schedule)
                    .font(DecompositionTypography.sectionTitle)
                Spacer()
                Button(DecompositionWorkbenchCopy.refreshProposals) {
                    model.refreshCalendarProposals()
                }
                .buttonStyle(.plain)
                .font(DecompositionTypography.auxiliary)
                .foregroundStyle(theme.controlAccent)
                .disabled(model.isCommitting)
                .help("按当前行动顺序重新建议未来七天的可用时间")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(scheduledCandidates) { candidate in
                        scheduleRow(candidate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(!model.isCommitting)
    }

    @ViewBuilder
    private func scheduleRow(_ candidate: CandidateAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title)
                .font(DecompositionTypography.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(candidate.completionDescription)
                .font(DecompositionTypography.auxiliary)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            DecompositionIdentifiedCheckbox(
                isOn: Binding(
                    get: { candidate.selectedForCalendar },
                    set: { selected in
                        model.setSelectedForCalendar(id: candidate.id, selected: selected)
                    }
                ),
                identifier: "decomposition-calendar-\(candidate.id.uuidString)",
                accessibilityName: "\(DecompositionWorkbenchCopy.joinCalendar)：\(candidate.title)",
                visualTitle: DecompositionWorkbenchCopy.joinCalendar,
                enabled: !model.isCommitting
            )
            .fixedSize()

            if candidate.selectedForCalendar {
                if candidate.proposal == nil {
                    Text(DecompositionWorkbenchCopy.noProposal)
                        .font(DecompositionTypography.auxiliary)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text(proposalSummary(candidate.proposal))
                        .font(DecompositionTypography.auxiliary)
                        .foregroundStyle(theme.secondaryText)
                }
                HStack(spacing: 10) {
                    EditorDateChip(
                        date: dateBinding(candidate),
                        accessibilityIdentifier: "decomposition-date-\(candidate.id.uuidString)",
                        accessibilityName: "日期"
                    )
                    .disabled(model.isCommitting)
                    EditorTimeChip(
                        date: timeBinding(candidate),
                        accessibilityIdentifier: "decomposition-time-\(candidate.id.uuidString)",
                        accessibilityName: "开始时间"
                    )
                    .disabled(model.isCommitting)
                    Picker("时长", selection: durationBinding(candidate)) {
                        ForEach(CandidateDuration.allCases, id: \.self) { duration in
                            Text("\(duration.rawValue) 分钟").tag(duration)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    .disabled(model.isCommitting)
                    .accessibilityIdentifier("decomposition-duration-\(candidate.id.uuidString)")
                    .accessibilityLabel("预计时长")
                    .accessibilityValue("\(candidate.estimatedDuration.rawValue) 分钟")
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 1)
        }
    }

    private func durationBinding(_ candidate: CandidateAction) -> Binding<CandidateDuration> {
        Binding(
            get: { candidate.estimatedDuration },
            set: { model.updateDuration(id: candidate.id, duration: $0) }
        )
    }

    private func dateBinding(_ candidate: CandidateAction) -> Binding<Date> {
        Binding(
            get: { model.editorInstant(id: candidate.id) },
            set: { model.updateProposalDate(id: candidate.id, instant: $0) }
        )
    }

    private func timeBinding(_ candidate: CandidateAction) -> Binding<Date> {
        Binding(
            get: { model.editorInstant(id: candidate.id) },
            set: { model.updateProposalTime(id: candidate.id, instant: $0) }
        )
    }

    private func proposalSummary(_ proposal: CalendarProposal?) -> String {
        guard let schedule = proposal?.schedule, let start = schedule.startTime, let end = schedule.endTime else {
            return DecompositionWorkbenchCopy.noProposal
        }
        return "\(schedule.startDate.month) 月 \(schedule.startDate.day) 日 \(timeText(start))–\(timeText(end))"
    }

    private func timeText(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }
}
