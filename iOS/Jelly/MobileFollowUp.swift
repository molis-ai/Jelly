import SwiftUI
import WorkspaceDomain

/// Phone version of the expansion block: same data and decisions as the Mac.
struct MobileExpansionSection: View {
    let inspiration: Inspiration
    let followUp: InspirationFollowUpService

    var body: some View {
        if followUp.canExpand(inspiration) || inspiration.expansion != nil {
            Section {
                if followUp.runningExpansions.contains(inspiration.id) {
                    ProgressView("正在补一句…")
                } else if let expansion = inspiration.expansion {
                    Text(expansion.supplement).textSelection(.enabled)
                    ForEach(expansion.directions) { direction in
                        HStack {
                            Text(direction.text)
                                .foregroundStyle(direction.decision == .ignored ? .secondary : .primary)
                                .strikethrough(direction.decision == .ignored)
                            Spacer()
                            switch direction.decision {
                            case .pending:
                                Button("采纳") { decide(direction, .adopted) }.buttonStyle(.borderless)
                                Button("忽略") { decide(direction, .ignored) }.buttonStyle(.borderless)
                            case .adopted:
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            case .ignored:
                                Button("撤回") { decide(direction, .pending) }.buttonStyle(.borderless)
                            }
                        }
                    }
                } else if !followUp.isModelConfigured {
                    Text("在设置里选好模型后，收下的想法会自动补一句、给几个方向。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = followUp.messages[inspiration.id] {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("延展")
                    Spacer()
                    if followUp.isModelConfigured, followUp.canExpand(inspiration),
                       !followUp.runningExpansions.contains(inspiration.id) {
                        Button(inspiration.expansion == nil ? "延展" : "重新延展") {
                            followUp.startExpansion(inspiration.id)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
    }

    private func decide(_ direction: ExpansionDirection, _ decision: ExpansionDirectionDecision) {
        Task { await followUp.decide(inspiration.id, directionID: direction.id, decision: decision) }
    }
}

struct MobileScheduleMenu: View {
    let onSchedule: (InspirationScheduleChoice) -> Void

    var body: some View {
        Menu {
            Button("今天") { onSchedule(.today) }
            Button("明天") { onSchedule(.tomorrow) }
            Button("放进无日期清单") { onSchedule(.undated) }
        } label: {
            Label("变成待办", systemImage: "calendar.badge.plus")
        }
    }
}
