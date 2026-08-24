import CalendarDomain
import SwiftUI

struct DecompositionScheduleEditor: View {
    @Bindable var model: DecompositionWorkbenchModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsRefreshAllConfirmation = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var scheduledCandidates: [CandidateAction] {
        model.draft.candidates.filter(\.selectedForCreation)
    }

    private var hasLockedSchedule: Bool {
        model.draft.candidates.contains { $0.selectedForCreation && $0.scheduleLockedByUser }
    }

    private var lockedScheduleCount: Int {
        model.draft.candidates.filter { $0.selectedForCreation && $0.scheduleLockedByUser }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(DecompositionWorkbenchCopy.schedule)
                    .font(DecompositionTypography.sectionTitle)
                Spacer()
                DecompositionIdentifiedButton(
                    title: DecompositionWorkbenchCopy.refreshProposals,
                    identifier: "decomposition-refresh-proposals",
                    accessibilityName: DecompositionWorkbenchCopy.refreshProposals,
                    helpText: DecompositionWorkbenchCopy.refreshProposalsHelp,
                    enabled: !model.isCommitting
                ) {
                    model.refreshCalendarProposals(overwriteUserAdjustments: false)
                }
                .frame(height: 22)
                .fixedSize()
                if hasLockedSchedule {
                    DecompositionIdentifiedButton(
                        title: DecompositionWorkbenchCopy.refreshAllProposals,
                        identifier: "decomposition-refresh-all-proposals",
                        accessibilityName: DecompositionWorkbenchCopy.refreshAllProposals,
                        helpText: DecompositionWorkbenchCopy.refreshAllProposalsHelp,
                        enabled: !model.isCommitting,
                        subdued: true
                    ) {
                        showsRefreshAllConfirmation = true
                    }
                    .frame(height: 22)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(scheduledCandidates) { candidate in
                        scheduleRow(candidate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(!model.isCommitting)
        .confirmationDialog(
            DecompositionWorkbenchCopy.overwriteAdjustedSchedules,
            isPresented: $showsRefreshAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(DecompositionWorkbenchCopy.confirmOverwriteAdjustedSchedules, role: .destructive) {
                model.refreshCalendarProposals(overwriteUserAdjustments: true)
            }
            Button(DecompositionWorkbenchCopy.keepAdjustedSchedules, role: .cancel) {}
        } message: {
            Text(DecompositionWorkbenchCopy.overwriteAdjustedSchedulesMessage(count: lockedScheduleCount))
        }
    }

    @ViewBuilder
    private func scheduleRow(_ candidate: CandidateAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.title)
                            .font(DecompositionTypography.body)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        if candidate.scheduleLockedByUser {
                            DecompositionAccessibleLabel(
                                text: DecompositionWorkbenchCopy.adjustedSchedule,
                                identifier: "decomposition-adjusted-\(candidate.id.uuidString)",
                                label: DecompositionWorkbenchCopy.adjustedSchedule,
                                textColor: theme.secondaryText
                            )
                            .fixedSize()
                        }
                    }
                    Text(candidate.completionDescription)
                        .font(DecompositionTypography.auxiliary)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                    enabled: !model.isCommitting,
                    requestsInitialFocus: candidate.id == scheduledCandidates.first?.id
                )
                .fixedSize()
            }

            if candidate.selectedForCalendar {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let proposal = candidate.proposal {
                        Text(proposalSummary(proposal))
                            .font(DecompositionTypography.auxiliary)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize()
                    } else {
                        DecompositionAccessibleLabel(
                            text: DecompositionWorkbenchCopy.noAvailableSlot,
                            identifier: "decomposition-no-slot-\(candidate.id.uuidString)",
                            label: DecompositionWorkbenchCopy.noAvailableSlot,
                            textColor: theme.secondaryText
                        )
                    }
                    Spacer(minLength: 12)
                    if candidate.proposal == nil {
                        DecompositionIdentifiedButton(
                            title: DecompositionWorkbenchCopy.chooseDateAndTime,
                            identifier: "decomposition-choose-time-\(candidate.id.uuidString)",
                            accessibilityName: DecompositionWorkbenchCopy.chooseDateAndTime,
                            enabled: !model.isCommitting,
                            isBordered: true
                        ) {
                            model.beginManualCalendarProposal(id: candidate.id)
                        }
                        .frame(minWidth: 128, maxHeight: 28)
                        .fixedSize()
                    } else {
                        HStack(spacing: 10) {
                            EditorDateChip(
                                date: dateBinding(candidate),
                                accessibilityIdentifier: "decomposition-date-\(candidate.id.uuidString)",
                                accessibilityName: "日期"
                            )
                            .disabled(model.isCommitting)
                            .background {
                                DecompositionIdentifiedHost(
                                    identifier: "decomposition-date-\(candidate.id.uuidString)"
                                )
                            }
                            EditorTimeChip(
                                date: timeBinding(candidate),
                                accessibilityIdentifier: "decomposition-time-\(candidate.id.uuidString)",
                                accessibilityName: "开始时间"
                            )
                            .disabled(model.isCommitting)
                            .background {
                                DecompositionIdentifiedHost(
                                    identifier: "decomposition-time-\(candidate.id.uuidString)"
                                )
                            }
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
                            .background {
                                DecompositionIdentifiedHost(
                                    identifier: "decomposition-duration-\(candidate.id.uuidString)"
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.58), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
