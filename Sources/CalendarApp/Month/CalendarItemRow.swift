import CalendarDomain
import SwiftUI

enum ItemCompletionRouter {
    static func command(for item: ProjectedItem, now: Date) -> CalendarCommand? {
        // Unified TODO: every item can be completed, timed or not.
        switch item {
        case let .item(item):
            return .setTaskCompleted(item.id, item.completedAt == nil ? now : nil)
        case let .occurrence(occurrence):
            return .setOccurrenceCompleted(
                occurrence.key,
                occurrence.completedAt == nil ? now : nil
            )
        }
    }
}

enum CalendarItemRowHitTarget {
    case completion
    case rowBody
}

struct CalendarItemAccessibility: Equatable {
    let label: String
    let value: String

    static func make(item: ProjectedItem, categoryName: String) -> CalendarItemAccessibility {
        var components = ["事项", categoryName, item.title, dateTimeRangeText(for: item.schedule)]
        components.append(item.completedAt == nil ? "未完成" : "已完成")
        return CalendarItemAccessibility(
            label: components.joined(separator: "，"),
            value: sourceValue(for: item)
        )
    }

    static func sourceValue(for item: ProjectedItem) -> String {
        "来源事项 \(sourceIdentifier(for: item))"
    }

    static func completionLabel(isCompleted: Bool) -> String {
        isCompleted ? "标记为未完成" : "标记为已完成"
    }

    static func sourceIdentifier(for item: ProjectedItem) -> String {
        switch item {
        case let .item(item):
            "item:\(item.id.uuidString)"
        case let .occurrence(occurrence):
            "occurrence:\(occurrence.key.seriesID.uuidString):\(dateIdentifier(occurrence.key.originalDate))"
        }
    }

    static func dateTimeRangeText(for schedule: CalendarSchedule) -> String {
        let includesYear = schedule.startDate.year != schedule.endDate.year
        let startDate = dateText(schedule.startDate, includesYear: includesYear)
        let endDate = dateText(schedule.endDate, includesYear: includesYear)
        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            return schedule.startDate == schedule.endDate
                ? startDate
                : "\(startDate)至\(endDate)"
        }
        if schedule.startDate == schedule.endDate {
            return "\(startDate) \(timeText(startTime))至\(timeText(endTime))"
        }
        return "\(startDate) \(timeText(startTime))至\(endDate) \(timeText(endTime))"
    }

    static func fullDateText(_ date: CalendarDate) -> String {
        dateText(date, includesYear: true)
    }

    private static func dateText(_ date: CalendarDate, includesYear: Bool) -> String {
        includesYear
            ? "\(date.year)年\(date.month)月\(date.day)日"
            : "\(date.month)月\(date.day)日"
    }

    private static func timeText(_ time: MinuteOfDay) -> String {
        String(format: "%02d:%02d", time.value / 60, time.value % 60)
    }

    private static func dateIdentifier(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}

struct CalendarItemRowInteraction {
    let completionCommand: CalendarCommand?
    let selectedDetailID: String?
}

enum CalendarItemRowInteractionRouter {
    static func route(
        target: CalendarItemRowHitTarget,
        item: ProjectedItem,
        now: Date
    ) -> CalendarItemRowInteraction {
        switch target {
        case .completion:
            return .init(
                completionCommand: ItemCompletionRouter.command(for: item, now: now),
                selectedDetailID: nil
            )
        case .rowBody:
            return .init(completionCommand: nil, selectedDetailID: item.id)
        }
    }
}

struct CalendarItemRowLayout: Equatable {
    let titleMinimumWidth: CGFloat?
    let timeLayoutPriority: Double
    let titleLayoutPriority: Double
    let inlineSpacing: CGFloat
    let textFontSize: CGFloat

    static let standard = CalendarItemRowLayout(
        titleMinimumWidth: 24,
        timeLayoutPriority: 3,
        titleLayoutPriority: 1,
        inlineSpacing: 4,
        textFontSize: 12
    )

    static let compact = CalendarItemRowLayout(
        titleMinimumWidth: 20,
        timeLayoutPriority: 4,
        titleLayoutPriority: 1,
        inlineSpacing: 3,
        textFontSize: 11
    )
}

/// Geometry shared by the rendered chip and its parent drag hit routing.
/// Keep these values here so the visible completion/resize affordances cannot drift
/// away from the regions used by `WeekRowItemHitRouting`.
enum CalendarItemRowInteractionGeometry {
    static let horizontalPadding: CGFloat = 6
    static let contentSpacing: CGFloat = 4
    static let completionWidth: CGFloat = 16
    static let handleWidth: CGFloat = 10
    /// Month chips are a cell wide; a 10pt handle is too easy to miss.
    static let generousEdgeHandleWidth: CGFloat = 32

    static var completionUpperBound: CGFloat {
        horizontalPadding + completionWidth + contentSpacing
    }

    static var leadingHandleRange: ClosedRange<CGFloat> {
        leadingHandleRange(generousEdges: false)
    }

    static func leadingHandleRange(generousEdges: Bool) -> ClosedRange<CGFloat> {
        let handle = generousEdges ? generousEdgeHandleWidth : handleWidth
        return completionUpperBound...(completionUpperBound + handle)
    }

    static func trailingHandleLowerBound(width: CGFloat, generousEdges: Bool = false) -> CGFloat {
        let handle = generousEdges
            ? generousEdgeHandleWidth
            : horizontalPadding + handleWidth
        return max(completionUpperBound, width - handle)
    }
}

enum CalendarItemTimeTextStyle: Equatable, Sendable {
    /// Month cells: start clock only, so the title can use the rest of the chip.
    case startOnly
    /// Week grid and day drawer: same-day `HH:mm–HH:mm` when end differs.
    case range
}

struct CalendarItemRowPresentation: Equatable {
    /// Always nil on-screen: category is color-only (TickTick-style). Kept in accessibility labels.
    let categoryName: String?
    let timeText: String?
    let title: String
    let accessibilityLabel: String
    let layout: CalendarItemRowLayout

    private static let compactRowContentWidth = 140.0
    /// Rough advance width of one monospacedDigit character at the compact
    /// font size; used only to decide whether a clock can share the chip.
    private static let estimatedTimeCharacterWidth = 6.8
    /// Priority badge + safety margin reserved ahead of the title.
    private static let leadingReserveWidth = 20.0
    /// Below roughly three CJK characters of title space, drop the clock so
    /// the title never degrades into unreadable fragments in narrow cells.
    private static let minimumReadableTitleWidth = 40.0

    static func make(
        availableContentWidth: Double,
        categoryName: String,
        timeRange: LocalTimeRange?,
        title: String
    ) -> CalendarItemRowPresentation {
        let timeText = timeRange.map { range in
            range.start == range.end
                ? timeString(range.start)
                : "\(timeString(range.start))–\(timeString(range.end))"
        }
        return CalendarItemRowPresentation(
            categoryName: nil,
            timeText: readableTimeText(
                candidate: timeText,
                availableContentWidth: availableContentWidth
            ),
            title: title,
            accessibilityLabel: rowBodyAccessibilityLabel(
                categoryName: categoryName,
                timeRange: timeRange,
                title: title
            ),
            layout: availableContentWidth <= compactRowContentWidth ? .compact : .standard
        )
    }

    static func make(
        availableContentWidth: Double,
        categoryName: String,
        schedule: CalendarSchedule,
        title: String,
        timeTextStyle: CalendarItemTimeTextStyle = .range
    ) -> CalendarItemRowPresentation {
        make(
            availableContentWidth: availableContentWidth,
            schedule: schedule,
            title: title,
            accessibilityLabel: rowBodyAccessibilityLabel(
                categoryName: categoryName,
                schedule: schedule,
                title: title,
                timeTextStyle: timeTextStyle
            ),
            timeTextStyle: timeTextStyle
        )
    }

    private static func make(
        availableContentWidth: Double,
        schedule: CalendarSchedule,
        title: String,
        accessibilityLabel: String,
        timeTextStyle: CalendarItemTimeTextStyle = .range
    ) -> CalendarItemRowPresentation {
        let isCompactRow = availableContentWidth <= compactRowContentWidth
        return CalendarItemRowPresentation(
            categoryName: nil,
            timeText: readableTimeText(
                candidate: displayTimeText(for: schedule, style: timeTextStyle),
                availableContentWidth: availableContentWidth
            ),
            title: title,
            accessibilityLabel: accessibilityLabel,
            layout: isCompactRow ? .compact : .standard
        )
    }

    /// Narrow-cell guard: when the remaining width after the clock and the
    /// leading badge cannot show a readable title, omit the clock entirely.
    /// Accessibility labels keep the full time regardless of this decision.
    private static func readableTimeText(
        candidate: String?,
        availableContentWidth: Double
    ) -> String? {
        guard let candidate else { return nil }
        let reserved = estimatedTimeCharacterWidth * Double(candidate.count)
            + leadingReserveWidth
            + minimumReadableTitleWidth
        guard availableContentWidth >= reserved else { return nil }
        return candidate
    }

    /// Visible chip time. Month cells keep start only so the title can use
    /// the rest of the chip; week / day-drawer keep the same-day range.
    static func displayTimeText(
        for schedule: CalendarSchedule,
        style: CalendarItemTimeTextStyle = .range
    ) -> String? {
        guard let start = schedule.startTime else { return nil }
        if style == .startOnly {
            return timeString(start)
        }
        guard let end = schedule.endTime else { return timeString(start) }
        if schedule.startDate == schedule.endDate, end != start {
            return "\(timeString(start))–\(timeString(end))"
        }
        return timeString(start)
    }

    static func rowBodyAccessibilityLabel(
        categoryName: String,
        timeRange: LocalTimeRange?,
        title: String
    ) -> String {
        var components = [categoryName]
        if let timeRange {
            components.append(timeString(timeRange.start))
        }
        components.append(title)
        return components.joined(separator: ", ")
    }

    static func rowBodyAccessibilityLabel(
        categoryName: String,
        schedule: CalendarSchedule,
        title: String,
        timeTextStyle: CalendarItemTimeTextStyle = .range
    ) -> String {
        var components = [categoryName]
        if let time = displayTimeText(for: schedule, style: timeTextStyle) {
            components.append(time)
        }
        components.append(title)
        return components.joined(separator: ", ")
    }

    static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }
}

struct CalendarItemRow: View {
    let item: ProjectedItem
    let category: CalendarCategory?
    var onCompletion: ((CalendarCommand) -> Void)?
    var onOpenDetail: ((ProjectedItem) -> Void)?
    var onDelete: (() -> Void)?
    var onSetPriority: ((ItemPriority) -> Void)?
    var allowsSwipeToDelete = true
    var accessibilityLabelOverride: String?
    var accessibilityValueOverride: String?
    var continuesBefore = false
    var continuesAfter = false
    var showsLeadingHandle = false
    var showsTrailingHandle = false
    var leadingHandleAccessibility: CalendarResizeHandleAccessibility?
    var trailingHandleAccessibility: CalendarResizeHandleAccessibility?
    /// Month cells use `.startOnly` so the title can occupy the leftover width.
    var timeTextStyle: CalendarItemTimeTextStyle = .range
    /// Focus ring driven by the day drawer's arrow-key navigation.
    var isKeyboardSelected = false
    /// When set, this row can accept a same-day untimed reorder (or a
    /// date-move fallback). Timed / week-resize chips leave this nil.
    var onDropTransfer: ((CalendarTransferPayload) -> Bool)?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var categoryHex: String {
        category?.colorHex ?? "#8C8F96"
    }

    private var itemColorRoles: CategoryRenderedColorRoles? {
        CalendarTheme.categoryItemRoles(
            categoryHex,
            isCompleted: isCompletedTask,
            appearance: appearance
        )
    }

    private var categoryColor: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.accent) }
            ?? CalendarTheme.categoryColor(categoryHex)
    }

    private var categoryBackground: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.background) }
            ?? CalendarTheme.itemBackground(
                CalendarTheme.categoryColor(categoryHex),
                appearance: appearance
            )
    }

    private var categoryText: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.text) }
            ?? theme.primaryText
    }

    private var isCompletedTask: Bool {
        item.completedAt != nil
    }

    var body: some View {
        ItemRowActionChrome(
            allowsSwipeToDelete: allowsSwipeToDelete,
            onDelete: { onDelete?() }
        ) {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: CalendarItemRowInteractionGeometry.contentSpacing) {
            // Completion stays its own hit target; the rest of the chip opens edit.
            Button {
                let interaction = CalendarItemRowInteractionRouter.route(
                    target: .completion,
                    item: item,
                    now: Date()
                )
                if let command = interaction.completionCommand {
                    onCompletion?(command)
                }
            } label: {
                Image(systemName: isCompletedTask ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(categoryColor.opacity(isCompletedTask ? 0.85 : 0.75))
                    .frame(
                        width: CalendarItemRowInteractionGeometry.completionWidth,
                        height: CalendarTheme.itemRowHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(CalendarItemAccessibility.completionLabel(isCompleted: isCompletedTask))
            .accessibilityValue(isCompletedTask ? "已完成" : "未完成")

            HStack(spacing: CalendarItemRowInteractionGeometry.contentSpacing) {
                if continuesBefore {
                    continuationMarker(systemName: "arrow.left")
                }
                if showsLeadingHandle {
                    handleMarker(
                        leadingHandleAccessibility
                            ?? .init(label: "调整开始日期", value: CalendarItemAccessibility.fullDateText(item.schedule.startDate))
                    )
                }

                GeometryReader { proxy in
                    let presentation = CalendarItemRowPresentation.make(
                        availableContentWidth: proxy.size.width,
                        categoryName: category?.name ?? "未分类",
                        schedule: item.schedule,
                        title: item.title,
                        timeTextStyle: timeTextStyle
                    )
                    HStack(spacing: presentation.layout.inlineSpacing) {
                        ItemPriorityBadge(priority: item.priority)
                        Text(presentation.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: presentation.layout.titleMinimumWidth, alignment: .leading)
                            .layoutPriority(presentation.layout.titleLayoutPriority)
                        Spacer(minLength: 2)
                        if let timeText = presentation.timeText {
                            Text(timeText)
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(presentation.layout.timeLayoutPriority)
                                .opacity(0.72)
                        }
                    }
                    .font(.system(size: presentation.layout.textFontSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .foregroundStyle(categoryText)
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsTrailingHandle {
                    handleMarker(
                        trailingHandleAccessibility
                            ?? .init(label: "调整结束日期", value: CalendarItemAccessibility.fullDateText(item.schedule.endDate))
                    )
                }
                if continuesAfter {
                    continuationMarker(systemName: "arrow.right")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpenDetail?(item)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                accessibilityLabelOverride
                    ?? CalendarItemAccessibility.make(
                        item: item,
                        categoryName: category?.name ?? "未分类"
                    ).label
            )
            .accessibilityValue(
                accessibilityValueOverride
                    ?? CalendarItemAccessibility.make(
                        item: item,
                        categoryName: category?.name ?? "未分类"
                    ).value
            )
            .accessibilityAction {
                onOpenDetail?(item)
            }
        }
        .font(CalendarTheme.itemFont)
        .padding(.horizontal, CalendarItemRowInteractionGeometry.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CalendarTheme.itemRowHeight)
        // Dim content only — keep chip fill opaque so swipe actions never bleed through.
        .opacity(isCompletedTask ? CalendarTheme.completedItemOpacity(for: appearance) : 1)
        .background(
            categoryBackground,
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
        )
        .overlay {
            if isKeyboardSelected {
                RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
                    .stroke(theme.controlAccent.opacity(0.65), lineWidth: 1.5)
            }
        }
        .accessibilityAddTraits(isKeyboardSelected ? .isSelected : [])
        .contentShape(RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous))
        .contextMenu {
            if let onSetPriority {
                Picker(
                    "设置优先级",
                    selection: Binding(
                        get: { item.priority },
                        set: { onSetPriority($0) }
                    )
                ) {
                    ForEach(ItemPriority.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
            }
            if onSetPriority != nil, onDelete != nil {
                Divider()
            }
            if let onDelete {
                Button("删除事项", role: .destructive, action: onDelete)
            }
        }
        .draggable(transferPayload) {
            ItemDragPreviewChip(
                title: item.title,
                priority: item.priority,
                schedule: item.schedule,
                categoryHex: categoryHex,
                isCompleted: isCompletedTask
            )
            .frame(width: 168)
            .padding(4)
        }
        .modifier(UntimedReorderDropModifier(onDropTransfer: onDropTransfer))
    }

    private var transferPayload: CalendarTransferPayload {
        switch item {
        case let .item(item):
            .item(item.id)
        case let .occurrence(occurrence):
            .occurrence(occurrence.key)
        }
    }

    @ViewBuilder
    private func continuationMarker(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(theme.secondaryText)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func handleMarker(_ accessibility: CalendarResizeHandleAccessibility) -> some View {
        Capsule()
            .fill(categoryColor.opacity(0.95))
            .frame(width: 4, height: max(10, CalendarTheme.itemRowHeight - 6))
            .frame(
                width: CalendarItemRowInteractionGeometry.handleWidth,
                height: CalendarTheme.itemRowHeight
            ) // larger grab affordance
            .contentShape(Rectangle())
            .accessibilityLabel(accessibility.label)
            .accessibilityValue(accessibility.value)
            .help("\(accessibility.label)，拖动以调整 · \(accessibility.value)")
    }
}

private struct UntimedReorderDropModifier: ViewModifier {
    let onDropTransfer: ((CalendarTransferPayload) -> Bool)?

    func body(content: Content) -> some View {
        if let onDropTransfer {
            content.dropDestination(for: CalendarTransferPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return onDropTransfer(payload)
            }
        } else {
            content
        }
    }
}
