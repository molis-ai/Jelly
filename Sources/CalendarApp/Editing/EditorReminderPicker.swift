import CalendarDomain
import SwiftUI

/// 提醒 row under the schedule. Options follow the schedule: lead times for
/// 定时 items, a clock time on the day for 全天 items.
struct EditorReminderPicker: View {
    @Binding var reminder: ItemReminder?
    let usesTime: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    static let allDayTimes: [MinuteOfDay] = [8, 9, 12, 18, 20].compactMap { MinuteOfDay(hour: $0, minute: 0) }

    static func options(usesTime: Bool) -> [ItemReminder] {
        usesTime
            ? ItemReminder.allowedLeadMinutes.map { .beforeStart(minutes: $0) }
            : allDayTimes.map { .onStartDay(at: $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("提醒")
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
                .frame(width: EditorFormStyle.labelWidth, alignment: .leading)
            Menu {
                Button("不提醒") { reminder = nil }
                Divider()
                ForEach(Self.options(usesTime: usesTime), id: \.self) { option in
                    Button(option.title) { reminder = option }
                }
            } label: {
                Label(currentTitle, systemImage: reminder == nil ? "bell.slash" : "bell")
                    .font(EditorFormStyle.control)
                    .foregroundStyle(reminder == nil ? theme.secondaryText : theme.primaryText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("提醒：\(currentTitle)")
            .accessibilityIdentifier("item-reminder-picker")
            Spacer(minLength: 0)
        }
        .frame(minHeight: EditorFormStyle.fieldMinHeight)
        .help("写进系统“提醒事项”的 Jelly 列表，靠 iCloud 在手机上响；在设置 › 提醒里打开")
        .onChange(of: usesTime) { _, _ in
            guard let current = reminder else { return }
            if usesTime, case .onStartDay = current {
                reminder = .beforeStart(minutes: 10)
            } else if !usesTime, case .beforeStart = current {
                reminder = .onStartDay(at: ItemReminder.defaultAllDayTime)
            }
        }
    }

    private var currentTitle: String {
        guard let reminder else { return "不提醒" }
        return reminder.title
    }
}
