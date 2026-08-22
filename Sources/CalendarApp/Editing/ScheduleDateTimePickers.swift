import CalendarDomain
import SwiftUI

// MARK: - Shared form typography (create + edit)
// One scale so title / labels / chips / popovers don't fight each other.

enum EditorFormStyle {
    /// Card chrome title — “编辑事项” / “新建事项”
    static let title = Font.system(size: 13, weight: .semibold)
    /// Title text field
    static let body = Font.system(size: 13)
    /// Row labels — 分类 / 开始 / 结束
    static let label = Font.system(size: 11.5)
    /// Menu values, chip text (date/time)
    static let control = Font.system(size: 12, weight: .medium)
    static let controlDigit = Font.system(size: 12, weight: .medium).monospacedDigit()
    /// 全天 / 定时 segment
    static func segment(selected: Bool) -> Font {
        .system(size: 11, weight: selected ? .semibold : .medium)
    }
    /// Errors, footnotes
    static let caption = Font.system(size: 11)
    /// Icons inside chips
    static let chipIcon = Font.system(size: 10, weight: .semibold)
    /// Quiet disclosure caret — never the system popup “up-down” pair
    static let chevron = Font.system(size: 7, weight: .bold)

    static let labelWidth: CGFloat = 36
    /// Label-to-category-tag gap; tighter than schedule field columns
    static let categoryLabelSpacing: CGFloat = 6
    static let fieldMinHeight: CGFloat = 28
    static let blockPadding: CGFloat = 10
    static let blockSpacing: CGFloat = 10
    static let contentSpacing: CGFloat = 12
}

/// Compact category tag used in create + edit. A chip, not a stretched popup.
struct EditorCategoryPicker: View {
    let categories: [CalendarCategory]
    let selectedID: UUID
    let footerTitle: String
    let onSelect: (UUID) -> Void
    let onFooter: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var selected: CalendarCategory? {
        categories.first { $0.id == selectedID }
    }

    private var selectedName: String {
        selected?.name ?? "未分类"
    }

    private var selectedHex: String {
        selected?.colorHex ?? "#8C8F96"
    }

    var body: some View {
        Menu {
            ForEach(categories) { category in
                Button {
                    onSelect(category.id)
                } label: {
                    Text(category.name)
                    CalendarTheme.categoryTagDotImage(category.colorHex, appearance: appearance)
                    if category.id == selectedID {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            Button(footerTitle) {
                // Menu teardown cancels same-turn sheet/overlay presentation.
                let action = onFooter
                DispatchQueue.main.async {
                    action()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(CalendarTheme.categoryTagColor(selectedHex, appearance: appearance))
                    .frame(width: 8, height: 8)
                Text(selectedName)
                    .font(EditorFormStyle.control)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(EditorFormStyle.chevron)
                    .foregroundStyle(theme.secondaryText.opacity(0.72))
                    .padding(.leading, 1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(
                theme.subtleBorder.opacity(isHovering ? 0.42 : 0.26),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(theme.subtleBorder.opacity(isHovering ? 0.7 : 0.48), lineWidth: 0.5)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .accessibilityLabel("分类 \(selectedName)")
        .help("选择分类")
    }
}

/// Full-row disclosure. macOS `DisclosureGroup` only hits the tiny chevron;
/// this button owns the entire label row.
struct EditorMoreDetailsDisclosure<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("更多详情")
                        .font(EditorFormStyle.control)
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(EditorFormStyle.chevron)
                        .foregroundStyle(theme.secondaryText.opacity(0.72))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: EditorFormStyle.fieldMinHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.subtleBorder.opacity(isHovering ? 0.18 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(EditorFullRowButtonStyle())
            .onHover { isHovering = $0 }
            .accessibilityLabel("更多详情")
            .accessibilityValue(isExpanded ? "已展开" : "已收起")

            if isExpanded {
                content()
                    .padding(.top, 8)
            }
        }
    }
}

/// macOS `.plain` buttons ignore empty space unless the style itself is a hit target.
private struct EditorFullRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Shared 每天 / 每周 / 一二三… track so weekday chips cannot drift larger.
private struct EditorSegmentTrack<Item: Hashable>: View {
    let items: [Item]
    let isSelected: (Item) -> Bool
    let title: (Item) -> String
    let accessibilityLabel: (Item) -> String
    let action: (Item) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let selected = isSelected(item)
                Button {
                    action(item)
                } label: {
                    Text(title(item))
                        .font(EditorFormStyle.segment(selected: selected))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.elevatedSurface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            theme.subtleBorder.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}

struct EditorRecurrenceModePicker: View {
    @Binding var mode: ItemRecurrenceMode
    /// Create form can tap the selected chip to go back to no repeat.
    var allowsClearing = true

    private static let options: [ItemRecurrenceMode] = [.daily, .weekly]

    var body: some View {
        EditorSegmentTrack(
            items: Self.options,
            isSelected: { mode == $0 },
            title: { $0.title },
            accessibilityLabel: { $0.title },
            action: { value in
                if mode == value, allowsClearing {
                    mode = .none
                } else {
                    mode = value
                }
            }
        )
    }
}

struct EditorWeekdayPicker: View {
    @Binding var weekdays: Set<Weekday>

    private static let names = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        EditorSegmentTrack(
            items: Array(Weekday.allCases),
            isSelected: { weekdays.contains($0) },
            title: { Self.names[$0.rawValue - 1] },
            accessibilityLabel: { "星期\(Self.names[$0.rawValue - 1])" },
            action: { weekday in
                if weekdays.contains(weekday) {
                    weekdays.remove(weekday)
                } else {
                    weekdays.insert(weekday)
                }
            }
        )
    }
}

struct EditorPriorityPicker: View {
    @Binding var priority: ItemPriority
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private static let options: [(ItemPriority, String)] = [
        (.none, "无"),
        (.p0, "P0"),
        (.p1, "P1"),
        (.p2, "P2")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.options, id: \.0) { value, title in
                let selected = priority == value
                Button {
                    priority = value
                } label: {
                    Text(title)
                        .font(EditorFormStyle.segment(selected: selected))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.elevatedSurface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("优先级 \(title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            theme.subtleBorder.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .frame(maxWidth: 200)
    }
}

// MARK: - Date / time chips (create & edit)

// MARK: Shared metrics (date + time popovers stay in one family)

private enum EditorPopoverMetrics {
    static let width: CGFloat = 260
    static let paddingH: CGFloat = 12
    static let paddingV: CGFloat = 10
    static let sectionGap: CGFloat = 8

    static let titleSize: CGFloat = 12.5
    static let labelSize: CGFloat = 11
    static let digitSize: CGFloat = 12.5
    static let chipLabelSize: CGFloat = 11

    static let dayCell: CGFloat = 30
    static let dayGap: CGFloat = 3
    static let navButton: CGFloat = 26

    static let cardCorner: CGFloat = 7
    static let chipCorner: CGFloat = 6
}

// MARK: Chip chrome

private enum EditorChipMetrics {
    static let corner: CGFloat = 6
    static let hPad: CGFloat = 8
    static let vPad: CGFloat = 5
}

private struct EditorChipBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: EditorChipMetrics.corner, style: .continuous)
            .fill(theme.elevatedSurface)
            .overlay {
                RoundedRectangle(cornerRadius: EditorChipMetrics.corner, style: .continuous)
                    .stroke(theme.subtleBorder.opacity(0.55), lineWidth: 0.5)
            }
            .shadow(
                color: Color(hexShadow: theme.subtleShadowHex).opacity(colorScheme == .dark ? 0.35 : 0.08),
                radius: 2,
                y: 1
            )
    }
}

private extension Color {
    init(hexShadow hex: String) {
        self = CalendarTheme.categoryColor(hex)
    }
}

// MARK: - Date chip

struct EditorDateChip: View {
    @Binding var date: Date
    var accessibilityIdentifier: String? = nil
    var accessibilityName: String = "日期"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(EditorFormStyle.chipIcon)
                    .foregroundStyle(theme.controlAccent.opacity(0.9))
                Text(Self.displayText(for: date))
                    .font(EditorFormStyle.controlDigit)
                    .foregroundStyle(theme.primaryText)
            }
            .padding(.horizontal, EditorChipMetrics.hPad)
            .padding(.vertical, EditorChipMetrics.vPad)
            .background(EditorChipBackground())
            .contentShape(RoundedRectangle(cornerRadius: EditorChipMetrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Self.displayText(for: date))
        .accessibilityAddTraits(.isButton)
        .modifier(OptionalAccessibilityIdentifier(accessibilityIdentifier))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EditorMonthCalendar(date: $date) {
                isPresented = false
            }
            .preferredColorScheme(colorScheme)
        }
    }

    static func displayText(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 0
        let month = c.month ?? 1
        let day = c.day ?? 1
        let thisYear = calendar.component(.year, from: Date())
        if year == thisYear {
            return String(format: "%d月%d日", month, day)
        }
        return String(format: "%d年%d月%d日", year, month, day)
    }
}

// MARK: - Custom month calendar

private struct EditorMonthCalendar: View {
    @Binding var date: Date
    var onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var visibleMonth: Date

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    init(date: Binding<Date>, onSelect: @escaping () -> Void) {
        _date = date
        self.onSelect = onSelect
        _visibleMonth = State(initialValue: Self.startOfMonth(containing: date.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, EditorPopoverMetrics.sectionGap)

            weekdayRow
                .padding(.bottom, 6)

            dayGrid

            Divider()
                .overlay(theme.separator.opacity(0.5))
                .padding(.top, EditorPopoverMetrics.sectionGap)
                .padding(.bottom, 8)

            HStack {
                Button("今天") {
                    select(Date())
                }
                .font(.system(size: EditorPopoverMetrics.labelSize, weight: .medium))
                .foregroundStyle(theme.controlAccent)
                .buttonStyle(.plain)

                Spacer()

                Text(Self.displayText(for: date))
                    .font(.system(size: EditorPopoverMetrics.labelSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, EditorPopoverMetrics.paddingH)
        .padding(.vertical, EditorPopoverMetrics.paddingV)
        .frame(width: EditorPopoverMetrics.width)
        .background(theme.elevatedSurface)
    }

    private var header: some View {
        HStack(spacing: 0) {
            navButton(systemName: "chevron.left") {
                shiftMonth(-1)
            }
            Spacer(minLength: 8)
            Text(monthTitle)
                .font(.system(size: EditorPopoverMetrics.titleSize, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
            Spacer(minLength: 8)
            navButton(systemName: "chevron.right") {
                shiftMonth(1)
            }
        }
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: EditorPopoverMetrics.navButton, height: EditorPopoverMetrics.navButton)
                .background(
                    Circle().fill(theme.subtleBorder.opacity(0.2))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: EditorPopoverMetrics.dayGap) {
            ForEach(Self.weekdayLabels, id: \.self) { label in
                Text(label)
                    .font(.system(size: EditorPopoverMetrics.labelSize, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                    .frame(
                        width: EditorPopoverMetrics.dayCell,
                        height: 18
                    )
            }
        }
    }

    private var dayGrid: some View {
        let days = monthCells()
        return VStack(spacing: EditorPopoverMetrics.dayGap) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: EditorPopoverMetrics.dayGap) {
                    ForEach(0..<7, id: \.self) { col in
                        let index = row * 7 + col
                        if index < days.count {
                            dayCell(days[index])
                        } else {
                            Color.clear.frame(
                                width: EditorPopoverMetrics.dayCell,
                                height: EditorPopoverMetrics.dayCell
                            )
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ cell: DayCell) -> some View {
        let selected = isSameDay(cell.date, date)
        let today = isSameDay(cell.date, Date())
        return Button {
            select(cell.date)
        } label: {
            Text("\(cell.day)")
                .font(.system(
                    size: EditorPopoverMetrics.digitSize,
                    weight: selected ? .semibold : .regular
                ).monospacedDigit())
                .foregroundStyle(dayForeground(inMonth: cell.inMonth, selected: selected, today: today))
                .frame(
                    width: EditorPopoverMetrics.dayCell,
                    height: EditorPopoverMetrics.dayCell
                )
                .background {
                    if selected {
                        Circle().fill(theme.controlAccent)
                    } else if today {
                        Circle()
                            .stroke(theme.controlAccent.opacity(0.55), lineWidth: 1.2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(cell.inMonth ? 1 : 0.38)
        .accessibilityLabel(Self.fullDateLabel(for: cell.date))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func fullDateLabel(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%d年%d月%d日", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    private func dayForeground(inMonth: Bool, selected: Bool, today: Bool) -> Color {
        if selected {
            return colorScheme == .dark ? theme.canvas : Color.white
        }
        if today {
            return theme.controlAccent
        }
        return inMonth ? theme.primaryText : theme.secondaryText
    }

    private var monthTitle: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month], from: visibleMonth)
        return String(format: "%d年%d月", c.year ?? 0, c.month ?? 1)
    }

    private func shiftMonth(_ delta: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = Self.startOfMonth(containing: next)
        }
    }

    private func select(_ day: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var next = calendar.dateComponents([.year, .month, .day], from: day)
        let keep = calendar.dateComponents([.hour, .minute], from: date)
        next.hour = keep.hour
        next.minute = keep.minute
        next.second = 0
        if let resolved = calendar.date(from: next) {
            date = resolved
        }
        visibleMonth = Self.startOfMonth(containing: day)
        onSelect()
    }

    private struct DayCell: Identifiable {
        let id: String
        let date: Date
        let day: Int
        let inMonth: Bool
    }

    private func monthCells() -> [DayCell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2 // Monday

        let monthStart = visibleMonth
        guard
            let monthRange = calendar.range(of: .day, in: .month, for: monthStart),
            let firstWeekday = calendar.dateComponents([.weekday], from: monthStart).weekday
        else {
            return []
        }

        let mondayIndex = (firstWeekday + 5) % 7
        let leading = mondayIndex

        var cells: [DayCell] = []
        for offset in stride(from: leading, through: 1, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: monthStart) else { continue }
            let day = calendar.component(.day, from: d)
            cells.append(DayCell(id: "p-\(offset)-\(day)", date: d, day: day, inMonth: false))
        }
        for day in monthRange {
            guard let d = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { continue }
            cells.append(DayCell(id: "c-\(day)", date: d, day: day, inMonth: true))
        }
        let trailing = max(0, 42 - cells.count)
        if trailing > 0, let last = cells.last?.date {
            for i in 1...trailing {
                guard let d = calendar.date(byAdding: .day, value: i, to: last) else { continue }
                let day = calendar.component(.day, from: d)
                cells.append(DayCell(id: "t-\(i)-\(day)", date: d, day: day, inMonth: false))
            }
        }
        return cells
    }

    private static func startOfMonth(containing date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(
            year: c.year,
            month: c.month,
            day: 1,
            hour: 12
        )) ?? date
    }

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.isDate(a, inSameDayAs: b)
    }

    static func displayText(for date: Date) -> String {
        EditorDateChip.displayText(for: date)
    }
}

// MARK: - Time chip

struct EditorTimeChip: View {
    @Binding var date: Date
    var accessibilityIdentifier: String? = nil
    var accessibilityName: String = "开始时间"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @FocusState private var focusedField: TimeDigitField.Field?

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var hour: Int {
        Calendar.current.component(.hour, from: date)
    }

    private var minute: Int {
        Calendar.current.component(.minute, from: date)
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(EditorFormStyle.chipIcon)
                    .foregroundStyle(theme.controlAccent.opacity(0.9))
                Text(String(format: "%02d:%02d", hour, minute))
                    .font(EditorFormStyle.controlDigit)
                    .foregroundStyle(theme.primaryText)
            }
            .padding(.horizontal, EditorChipMetrics.hPad)
            .padding(.vertical, EditorChipMetrics.vPad)
            .background(EditorChipBackground())
            .contentShape(RoundedRectangle(cornerRadius: EditorChipMetrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(String(format: "%02d:%02d", hour, minute))
        .accessibilityAddTraits(.isButton)
        .modifier(OptionalAccessibilityIdentifier(accessibilityIdentifier))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            timePopover
                .preferredColorScheme(colorScheme)
        }
    }

    private var timePopover: some View {
        VStack(spacing: EditorPopoverMetrics.sectionGap) {
            HStack(spacing: 8) {
                TimeDigitField(
                    field: .hour,
                    value: hour,
                    range: 0...23,
                    focusedField: $focusedField,
                    onChange: setHour
                )
                Text(":")
                    .font(.system(size: EditorPopoverMetrics.digitSize, weight: .medium))
                    .foregroundStyle(theme.secondaryText.opacity(0.4))
                TimeDigitField(
                    field: .minute,
                    value: minute,
                    range: 0...59,
                    focusedField: $focusedField,
                    onChange: setMinute
                )
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: EditorPopoverMetrics.dayGap),
                    count: 4
                ),
                spacing: EditorPopoverMetrics.dayGap
            ) {
                ForEach(Self.quickTimes, id: \.self) { minutes in
                    let h = minutes / 60
                    let m = minutes % 60
                    let on = hour == h && minute == m
                    Button {
                        focusedField = nil
                        setHour(h)
                        setMinute(m)
                    } label: {
                        Text(String(format: "%02d:%02d", h, m))
                            .font(.system(
                                size: EditorPopoverMetrics.chipLabelSize,
                                weight: on ? .semibold : .medium
                            ).monospacedDigit())
                            .foregroundStyle(on ? Color.white : theme.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: EditorPopoverMetrics.dayCell - 4)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: EditorPopoverMetrics.chipCorner,
                                    style: .continuous
                                )
                                .fill(on ? theme.controlAccent : theme.subtleBorder.opacity(0.2))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: "%02d:%02d", h, m))
                }
            }
        }
        .padding(.horizontal, EditorPopoverMetrics.paddingH)
        .padding(.vertical, EditorPopoverMetrics.paddingV)
        .frame(width: EditorPopoverMetrics.width)
        .background(theme.elevatedSurface)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .hour
            }
        }
    }

    private func setHour(_ hour: Int) {
        apply(hour: hour, minute: minute)
    }

    private func setMinute(_ minute: Int) {
        apply(hour: hour, minute: min(59, max(0, minute)))
    }

    private func apply(hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let next = calendar.date(from: components) {
            date = next
        }
    }

    private static let quickTimes: [Int] = [
        9 * 60, 10 * 60, 11 * 60, 12 * 60,
        13 * 60, 14 * 60, 15 * 60, 16 * 60,
        17 * 60, 18 * 60, 19 * 60, 20 * 60
    ]
}

/// Stepper + digit TextField — type to enter hour/minute manually.
private struct TimeDigitField: View {
    enum Field: Hashable {
        case hour
        case minute
    }

    let field: Field
    let value: Int
    let range: ClosedRange<Int>
    var focusedField: FocusState<Field?>.Binding
    let onChange: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String = ""

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var isFocused: Bool {
        focusedField.wrappedValue == field
    }

    private var accessibilityName: String {
        field == .hour ? "时" : "分"
    }

    var body: some View {
        VStack(spacing: 1) {
            Button {
                step(+1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("增加\(accessibilityName)")

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isFocused
                              ? theme.controlAccent.opacity(0.14)
                              : theme.subtleBorder.opacity(0.12))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            isFocused ? theme.controlAccent.opacity(0.55) : Color.clear,
                            lineWidth: 1
                        )
                }
                .focused(focusedField, equals: field)
                .onSubmit { commitAndAdvance() }
                .accessibilityLabel(accessibilityName)
                .help("点击输入\(accessibilityName)")

            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("减少\(accessibilityName)")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: EditorPopoverMetrics.cardCorner, style: .continuous)
                .fill(theme.subtleBorder.opacity(0.16))
        )
        .onAppear { text = formatted(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused {
                text = formatted(newValue)
            }
        }
        .onChange(of: text) { _, newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(2))
            if digits != newValue {
                text = digits
                return
            }
            if digits.count == 2 {
                commit(digits)
                if field == .hour {
                    focusedField.wrappedValue = .minute
                }
            }
        }
        .onChange(of: focusedField.wrappedValue) { old, new in
            if old == field, new != field {
                commit(text)
            }
            if new == field {
                text = formatted(value)
            }
        }
    }

    private func step(_ delta: Int) {
        focusedField.wrappedValue = nil
        let span = range.upperBound - range.lowerBound + 1
        var next = value + delta
        if next > range.upperBound { next = range.lowerBound }
        if next < range.lowerBound { next = range.upperBound }
        if !range.contains(next) {
            next = range.lowerBound + ((value - range.lowerBound + delta) % span + span) % span
        }
        onChange(next)
        text = formatted(next)
    }

    private func commitAndAdvance() {
        commit(text)
        if field == .hour {
            focusedField.wrappedValue = .minute
        } else {
            focusedField.wrappedValue = nil
        }
    }

    private func commit(_ raw: String) {
        let clamped: Int
        if let parsed = Int(raw) {
            clamped = min(range.upperBound, max(range.lowerBound, parsed))
        } else {
            clamped = value
        }
        if clamped != value {
            onChange(clamped)
        }
        text = formatted(clamped)
    }

    private func formatted(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    init(_ identifier: String?) {
        self.identifier = identifier
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
