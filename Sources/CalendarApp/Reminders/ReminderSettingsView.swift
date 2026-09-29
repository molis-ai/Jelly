import CalendarDomain
import SwiftUI

struct ReminderSettingsView: View {
    let service: ReminderSyncService
    @State private var enabled = false
    @State private var reviewEnabled = true
    @State private var reviewTime = Date()
    @State private var working = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        JellySettingsPage {
            JellySettingsCard {
                Text("手机提醒")
                    .font(.system(size: 13, weight: .semibold))
                Toggle("把标了提醒的事项写进系统“提醒事项”", isOn: Binding(
                    get: { enabled },
                    set: { value in toggle(value) }
                ))
                .font(.system(size: 13))
                .toggleStyle(.switch)
                .disabled(working)
                caption("只写标了提醒的一次性事项，放在“提醒事项”里名为 Jelly 的列表。这个列表在 iCloud 账户下时，iPhone 和 Apple Watch 会一起响。Jelly 只写不读：你在手机上勾掉或删掉的提醒不会被写回，除非之后在 Jelly 里又改了这件事。")
                statusLine
                if enabled {
                    Button("立即同步") { Task { await service.syncNow() } }
                        .disabled(service.isSyncing)
                }
            }
            JellySettingsCard {
                Text("回顾提醒")
                    .font(.system(size: 13, weight: .semibold))
                Toggle("有旧灵感等回顾时，在这个时间提醒我", isOn: Binding(
                    get: { reviewEnabled },
                    set: { value in
                        reviewEnabled = value
                        service.settings.reviewEnabled = value
                        service.scheduleSync(after: .milliseconds(200))
                    }
                ))
                .font(.system(size: 13))
                .toggleStyle(.switch)
                DatePicker("时间", selection: Binding(
                    get: { reviewTime },
                    set: { value in
                        reviewTime = value
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                        if let time = MinuteOfDay(hour: parts.hour ?? 21, minute: parts.minute ?? 0) {
                            service.settings.reviewTime = time
                            service.scheduleSync()
                        }
                    }
                ), displayedComponents: .hourAndMinute)
                .disabled(!reviewEnabled)
                caption("没有待回顾的灵感时不会提醒。也通过上面的提醒事项列表送达，所以需要先打开手机提醒。")
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = service.lastError {
            Text(error).font(.system(size: 12)).foregroundStyle(theme.error)
        } else if service.isSyncing {
            Text("正在同步…").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
        } else if let outcome = service.lastOutcome, let at = service.lastSyncedAt {
            Text("\(at.formatted(date: .omitted, time: .shortened)) 同步：\(outcome.summary)")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        } else if enabled, service.authorization != .authorized {
            Text("还没有提醒事项权限。").font(.system(size: 12)).foregroundStyle(theme.error)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        enabled = service.settings.isEnabled
        reviewEnabled = service.settings.reviewEnabled
        let time = service.settings.reviewTime
        reviewTime = Calendar.current.date(
            bySettingHour: time.value / 60,
            minute: time.value % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func toggle(_ value: Bool) {
        working = true
        Task {
            if value {
                enabled = await service.enable()
            } else {
                await service.disable()
                enabled = false
            }
            working = false
        }
    }
}
