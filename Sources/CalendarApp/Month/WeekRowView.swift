import AppKit
import CalendarDomain
import SwiftUI

enum WeekRowMetrics {
    /// Compact week row; lane count follows itemRowHeight (not locked to 10).
    static let defaultHeight: CGFloat = 212
    /// Date numeral band + a little air above the first item chip.
    static let dateHeaderHeight: CGFloat = 26
    static let laneHeight: CGFloat = CalendarTheme.itemRowHeight
    static let laneSpacing: CGFloat = 2

    static func itemCapacity(height: CGFloat) -> Int {
        let laneAreaHeight = max(0, height - dateHeaderHeight)
        return max(0, Int(floor((laneAreaHeight + laneSpacing) / (laneHeight + laneSpacing))))
    }

    static func laneOffset(_ lane: Int) -> CGFloat {
        dateHeaderHeight + CGFloat(lane) * (laneHeight + laneSpacing)
    }
}

enum WeekRowDropTarget {
    static func date(atX x: CGFloat, rowWidth: CGFloat, weekStart: CalendarDate) -> CalendarDate {
        guard rowWidth > 0 else { return weekStart }
        let columnWidth = rowWidth / 7
        let column = min(max(Int(floor(x / columnWidth)), 0), 6)
        return weekStart.addingDays(column)
    }
}

struct CalendarDateBadgePresentation: Equatable {
    let showsTodayDot: Bool
    let showsSelectionRing: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    init(date: CalendarDate, isToday: Bool, isSelected: Bool) {
        showsTodayDot = isToday
        showsSelectionRing = isSelected

        var labelComponents = ["\(date.month)月\(date.day)日"]
        var stateComponents: [String] = []
        if isToday {
            labelComponents.append("今天")
            stateComponents.append("今天")
        }
        if isSelected {
            labelComponents.append("已选中")
            stateComponents.append("已选中")
        }
        labelComponents.append("打开当天事项")
        accessibilityLabel = labelComponents.joined(separator: "，")
        accessibilityValue = stateComponents.isEmpty
            ? "普通日期"
            : stateComponents.joined(separator: "，")
    }
}

struct WeekRowSegmentPresentation: Identifiable, Equatable {
    let id: WeekSegmentID
    let source: ProjectedEntryID
    let entry: ProjectedEntry
    let startColumn: Int
    let endColumn: Int
    let lane: Int
    let continuesBefore: Bool
    let continuesAfter: Bool
    let showsLeadingHandle: Bool
    let showsTrailingHandle: Bool
    let accessibilityLabel: String
    let accessibilityValue: String
    let leadingHandleAccessibility: CalendarResizeHandleAccessibility?
    let trailingHandleAccessibility: CalendarResizeHandleAccessibility?

    var leadingContinuation: Bool { continuesBefore }
    var trailingContinuation: Bool { continuesAfter }

    init(segment: WeekSegment, categoryName: String) {
        id = segment.id
        source = segment.source
        entry = segment.entry
        startColumn = segment.startColumn
        endColumn = segment.endColumn
        lane = segment.lane
        continuesBefore = segment.entry.schedule.startDate < segment.id.weekStart
        continuesAfter = segment.entry.schedule.endDate > segment.id.weekStart.addingDays(6)
        showsLeadingHandle = segment.showsLeadingHandle
        showsTrailingHandle = segment.showsTrailingHandle
        accessibilityLabel = Self.makeAccessibilityLabel(
            entry: segment.entry,
            categoryName: categoryName,
            continuesBefore: continuesBefore,
            continuesAfter: continuesAfter
        )
        accessibilityValue = Self.makeAccessibilityValue(entry: segment.entry)
        leadingHandleAccessibility = segment.showsLeadingHandle
            ? .init(
                label: "调整开始日期",
                value: CalendarItemAccessibility.fullDateText(segment.entry.schedule.startDate)
            )
            : nil
        trailingHandleAccessibility = segment.showsTrailingHandle
            ? .init(
                label: "调整结束日期",
                value: CalendarItemAccessibility.fullDateText(segment.entry.schedule.endDate)
            )
            : nil
    }

    private static func makeAccessibilityValue(entry: ProjectedEntry) -> String {
        let item: ProjectedItem = switch entry {
        case let .item(item): .item(item)
        case let .occurrence(occurrence): .occurrence(occurrence)
        }
        return CalendarItemAccessibility.sourceValue(for: item)
    }

    private static func makeAccessibilityLabel(
        entry: ProjectedEntry,
        categoryName: String,
        continuesBefore: Bool,
        continuesAfter: Bool
    ) -> String {
        var components = [
            "事项",
            categoryName,
            entry.title,
            CalendarItemAccessibility.dateTimeRangeText(for: entry.schedule)
        ]
        if continuesBefore {
            components.append("从前一周继续")
        }
        if continuesAfter {
            components.append("延续到下一周")
        }
        components.append(entry.completedAt == nil ? "未完成" : "已完成")
        return components.joined(separator: "，")
    }

}

struct CalendarResizeHandleAccessibility: Equatable {
    let label: String
    let value: String
}

struct WeekRowPresentation: Equatable {
    let weekStart: CalendarDate
    let segments: [WeekRowSegmentPresentation]
    let overflowByDate: [CalendarDate: Int]

    init(layout: WeekLayout, categories: [UUID: CalendarCategory] = [:]) {
        weekStart = layout.weekStart
        overflowByDate = layout.overflowByDate
        segments = layout.visibleSegments.map { segment in
            WeekRowSegmentPresentation(
                segment: segment,
                categoryName: categories[segment.entry.categoryID]?.name ?? "未分类"
            )
        }
    }

    var accessibilityLabel: String {
        segments.map(\.accessibilityLabel).joined(separator: "；")
    }

    func segment(_ source: ProjectedEntryID) -> WeekRowSegmentPresentation? {
        segments.first(where: { $0.source == source })
    }

    func overflowCount(for date: CalendarDate) -> Int {
        overflowByDate[date, default: 0]
    }
}

struct WeekRowViewportFrame: Equatable, Identifiable {
    let weekStart: CalendarDate
    let minY: CGFloat
    let maxY: CGFloat
    let windowRevision: WeekStreamWindowRevision?

    init(
        weekStart: CalendarDate,
        minY: CGFloat,
        maxY: CGFloat,
        windowRevision: WeekStreamWindowRevision? = nil
    ) {
        self.weekStart = weekStart
        self.minY = minY
        self.maxY = maxY
        self.windowRevision = windowRevision
    }

    var id: CalendarDate { weekStart }
    var centerY: CGFloat { (minY + maxY) / 2 }
}

enum WeekStreamExtensionDirection: Equatable {
    case earlier
    case later
}

struct WeekStreamExtensionRequest: Equatable {
    let direction: WeekStreamExtensionDirection
    let anchor: WeekStreamAnchor
    let desiredMinY: CGFloat

    init(
        direction: WeekStreamExtensionDirection,
        anchor: WeekStreamAnchor,
        desiredMinY: CGFloat? = nil
    ) {
        self.direction = direction
        self.anchor = anchor
        self.desiredMinY = desiredMinY ?? -anchor.pixelOffset
    }
}

struct WeekStreamRestorationIntent: Equatable {
    let weekStart: CalendarDate
    let pixelOffset: CGFloat
}

enum WeekStreamViewport {
    static let edgeThreshold: CGFloat = WeekRowMetrics.defaultHeight

    static func focusWeek(
        in frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat
    ) -> CalendarDate? {
        let viewportCenter = viewportHeight / 2
        return frames.min {
            let leftDistance = abs($0.centerY - viewportCenter)
            let rightDistance = abs($1.centerY - viewportCenter)
            if leftDistance == rightDistance {
                return $0.weekStart < $1.weekStart
            }
            return leftDistance < rightDistance
        }?.weekStart
    }

    static func extensionRequest(
        in frames: [WeekRowViewportFrame],
        loadedWeekStarts: [CalendarDate],
        viewportHeight: CGFloat
    ) -> WeekStreamExtensionRequest? {
        guard let firstLoadedWeek = loadedWeekStarts.first,
              let lastLoadedWeek = loadedWeekStarts.last
        else {
            return nil
        }

        let framesByWeek = Dictionary(uniqueKeysWithValues: frames.map { ($0.weekStart, $0) })
        let visibleFrames = frames
            .filter { $0.maxY >= 0 && $0.minY <= viewportHeight }
            .sorted {
                if $0.minY == $1.minY {
                    return $0.weekStart < $1.weekStart
                }
                return $0.minY < $1.minY
            }
        guard let stableAnchor = visibleFrames.first else {
            return nil
        }

        if let firstFrame = framesByWeek[firstLoadedWeek],
           firstFrame.maxY >= 0,
           firstFrame.minY <= edgeThreshold {
            return WeekStreamExtensionRequest(
                direction: .earlier,
                anchor: .init(
                    weekStart: stableAnchor.weekStart,
                    pixelOffset: max(0, -stableAnchor.minY)
                ),
                desiredMinY: stableAnchor.minY
            )
        }
        if let lastFrame = framesByWeek[lastLoadedWeek],
           lastFrame.minY <= viewportHeight,
           lastFrame.maxY >= viewportHeight - edgeThreshold {
            return WeekStreamExtensionRequest(
                direction: .later,
                anchor: .init(
                    weekStart: stableAnchor.weekStart,
                    pixelOffset: max(0, -stableAnchor.minY)
                ),
                desiredMinY: stableAnchor.minY
            )
        }
        return nil
    }

    static func restorationIntent(for anchor: WeekStreamAnchor) -> WeekStreamRestorationIntent {
        .init(weekStart: anchor.weekStart, pixelOffset: anchor.pixelOffset)
    }
}

struct WeekRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [WeekRowViewportFrame] = []

    static func reduce(value: inout [WeekRowViewportFrame], nextValue: () -> [WeekRowViewportFrame]) {
        var frames = Dictionary(uniqueKeysWithValues: value.map { ($0.weekStart, $0) })
        for frame in nextValue() {
            frames[frame.weekStart] = frame
        }
        value = frames.values.sorted { $0.weekStart < $1.weekStart }
    }
}

struct CalendarDateFramePreferenceKey: PreferenceKey {
    static let defaultValue: [CalendarDateFrame] = []

    static func reduce(value: inout [CalendarDateFrame], nextValue: () -> [CalendarDateFrame]) {
        var frames = Dictionary(uniqueKeysWithValues: value.map { ($0.date, $0) })
        for frame in nextValue() {
            frames[frame.date] = frame
        }
        value = frames.values.sorted { $0.date < $1.date }
    }
}

enum WeekRowHitSurface: Equatable {
    case emptySurface
    case dateNumber
    case overflow
    case item
    case completion
    case scroll
}

enum WeekRowHitRouting {
    static func selectionTarget(for surface: WeekRowHitSurface) -> CalendarInteractionHitTarget? {
        switch surface {
        case .emptySurface:
            .emptyCell
        case .dateNumber, .overflow, .item, .completion, .scroll:
            nil
        }
    }

    static func dayAction(for surface: WeekRowHitSurface, date: CalendarDate) -> DayCellAction? {
        switch surface {
        case .dateNumber:
            DayCellSurfaceInteraction.controlAction(for: .dateNumber, date: date)
        case .overflow:
            DayCellSurfaceInteraction.controlAction(for: .overflow, date: date)
        case .emptySurface, .item, .completion, .scroll:
            nil
        }
    }
}

enum WeekRowItemHitRouting {
    static func target(
        atX x: CGFloat,
        width: CGFloat,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool,
        generousEdges: Bool = false
    ) -> CalendarInteractionHitTarget {
        let clampedX = min(max(x, 0), max(0, width))

        // Completion owns the leading button, its outer padding, and the following gap.
        // This check must precede handle routing because completion must never begin a resize.
        if clampedX <= CalendarItemRowInteractionGeometry.completionUpperBound {
            return .completionButton
        }
        if showsLeadingHandle,
           CalendarItemRowInteractionGeometry.leadingHandleRange(generousEdges: generousEdges)
            .contains(clampedX) {
            return .leadingHandle
        }
        if showsTrailingHandle,
           clampedX >= CalendarItemRowInteractionGeometry.trailingHandleLowerBound(
            width: width,
            generousEdges: generousEdges
           ) {
            return .trailingHandle
        }
        return .barBody
    }

    /// The production SwiftUI drag gesture uses this seam so completion clicks cannot
    /// accidentally start a move or resize operation.
    static func dragTarget(
        atX x: CGFloat,
        width: CGFloat,
        showsLeadingHandle: Bool,
        showsTrailingHandle: Bool,
        generousEdges: Bool = false
    ) -> CalendarInteractionHitTarget? {
        let target = target(
            atX: x,
            width: width,
            showsLeadingHandle: showsLeadingHandle,
            showsTrailingHandle: showsTrailingHandle,
            generousEdges: generousEdges
        )
        // A drag that starts on the checkbox still stretches the leading edge.
        // Short clicks stay completion because the gesture has a minimum distance.
        if target == .completionButton {
            return showsLeadingHandle ? .leadingHandle : .barBody
        }
        return target
    }
}

enum WeekRowPreviewLayout {
    static func columns(
        for schedule: CalendarSchedule,
        weekStart: CalendarDate
    ) -> (start: Int, end: Int)? {
        let weekEnd = weekStart.addingDays(6)
        guard schedule.startDate <= weekEnd, weekStart <= schedule.endDate else { return nil }
        let startDate = max(schedule.startDate, weekStart)
        let endDate = min(schedule.endDate, weekEnd)
        return (weekStart.days(until: startDate), weekStart.days(until: endDate))
    }
}

@MainActor
final class WeekRowRangeGestureSurfaceView: NSView {
    private var date: CalendarDate
    private var hitSurface: WeekRowHitSurface
    private var rootOrigin: CGPoint
    private var onRangeGesture: (WeekRowRangeGesture) -> Void
    private var isTrackingRange = false

    override var isFlipped: Bool { true }

    init(
        date: CalendarDate,
        hitSurface: WeekRowHitSurface,
        rootOrigin: CGPoint,
        onRangeGesture: @escaping (WeekRowRangeGesture) -> Void
    ) {
        self.date = date
        self.hitSurface = hitSurface
        self.rootOrigin = rootOrigin
        self.onRangeGesture = onRangeGesture
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        date: CalendarDate,
        hitSurface: WeekRowHitSurface,
        rootOrigin: CGPoint,
        onRangeGesture: @escaping (WeekRowRangeGesture) -> Void
    ) {
        self.date = date
        self.hitSurface = hitSurface
        self.rootOrigin = rootOrigin
        self.onRangeGesture = onRangeGesture
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Accept every point in the body. Occupied chips sit in a higher ZStack layer and
        // receive their own hits; masking whole lanes here left dead zones beside/under items
        // (e.g. day-cell bottom-left margins next to a chip).
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let target = WeekRowHitRouting.selectionTarget(for: hitSurface) else {
            isTrackingRange = false
            return
        }
        isTrackingRange = true
        onRangeGesture(.began(date, target, rootPoint(for: event)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingRange else { return }
        onRangeGesture(.changed(rootPoint(for: event)))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isTrackingRange = false }
        guard isTrackingRange else { return }
        onRangeGesture(.ended(rootPoint(for: event)))
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    private func rootPoint(for event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: rootOrigin.x + localPoint.x,
            y: rootOrigin.y + localPoint.y
        )
    }
}

private struct WeekRowEmptyRangeGestureSurface: NSViewRepresentable {
    let date: CalendarDate
    let rootOrigin: CGPoint
    let onRangeGesture: (WeekRowRangeGesture) -> Void

    func makeNSView(context _: Context) -> WeekRowRangeGestureSurfaceView {
        WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: rootOrigin,
            onRangeGesture: onRangeGesture
        )
    }

    func updateNSView(_ view: WeekRowRangeGestureSurfaceView, context _: Context) {
        view.update(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: rootOrigin,
            onRangeGesture: onRangeGesture
        )
    }
}

enum WeekRowRangeGesture {
    case began(CalendarDate, CalendarInteractionHitTarget, CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)

    static func target(for target: DayCellHitTarget) -> CalendarInteractionHitTarget {
        switch target {
        case .emptyArea:
            WeekRowHitRouting.selectionTarget(for: .emptySurface) ?? .emptyCell
        case .dateNumber:
            .dateNumber
        case .overflow:
            .overflow
        case .item:
            .barBody
        }
    }
}

enum WeekRowItemGesture {
    case began(CalendarDate, CalendarInteractionHitTarget, ProjectedEntry, CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)
}

struct WeekRowView: View {
    let layout: WeekLayout
    let today: CalendarDate
    let selectedDate: CalendarDate?
    let categories: [UUID: CalendarCategory]
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onAction: (DayCellAction) -> Void
    let onCompletion: (CalendarCommand) -> Void
    let selectionRange: CalendarDateRange?
    /// Source currently being dragged/resized — original chip is dimmed as a ghost.
    var draggingSourceID: ProjectedEntryID? = nil
    var draggingPreviewSchedule: CalendarSchedule? = nil
    var isResizingItem = false
    let onRangeGesture: (WeekRowRangeGesture) -> Void
    let onItemGesture: (WeekRowItemGesture) -> Void
    var onDeleteItem: ((ProjectedItem) -> Void)? = nil
    var onCopyToToday: ((ProjectedItem) -> Void)? = nil
    var onSetPriority: ((ProjectedItem, ItemPriority) -> Void)? = nil
    var height: CGFloat = WeekRowMetrics.defaultHeight

    private var presentation: WeekRowPresentation {
        WeekRowPresentation(layout: layout, categories: categories)
    }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let date = layout.weekStart.addingDays(column)
                        WeekRowDateCell(
                            date: date,
                            isToday: date == today,
                            isSelected: date == selectedDate,
                            isInSelection: selectionRange.map { $0.start <= date && date <= $0.end } ?? false,
                            overflow: presentation.overflowCount(for: date),
                            dropCoordinator: dropCoordinator,
                            onAction: onAction,
                            onRangeGesture: onRangeGesture
                        )
                        .frame(width: columnWidth, height: height)
                    }
                }

                ForEach(presentation.segments) { segment in
                    let display = previewDisplay(
                        for: segment,
                        columnWidth: columnWidth
                    )
                    WeekRowSegmentBar(
                        segment: segment,
                        category: categories[segment.entry.categoryID],
                        weekStart: layout.weekStart,
                        columnWidth: columnWidth,
                        dropCoordinator: dropCoordinator,
                        onItemGesture: onItemGesture,
                        onCompletion: onCompletion,
                        onOpenDetail: { item in
                            onAction(.openItem(item.id))
                        },
                        onDelete: onDeleteItem,
                        onCopyToToday: onCopyToToday,
                        onSetPriority: onSetPriority
                    )
                    // Inset chip without expanding dead zones: apply padding inside the frame
                    // so neighboring empty body stays hittable for create.
                    .padding(.horizontal, 2)
                    .frame(
                        width: display.width,
                        height: WeekRowMetrics.laneHeight
                    )
                    .opacity(display.opacity)
                    .offset(
                        x: display.x,
                        y: WeekRowMetrics.laneOffset(segment.lane)
                    )
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .dropDestination(for: CalendarTransferPayload.self) { payloads, location in
                guard let payload = payloads.first else { return false }
                let destination = WeekRowDropTarget.date(
                    atX: location.x,
                    rowWidth: proxy.size.width,
                    weekStart: layout.weekStart
                )
                Task {
                    try? await dropCoordinator.accept(payload, on: destination)
                }
                return true
            } isTargeted: { _ in
                // Date cells keep the targeted-date highlight; this parent also covers row overlays.
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private func previewDisplay(
        for segment: WeekRowSegmentPresentation,
        columnWidth: CGFloat
    ) -> (width: CGFloat, x: CGFloat, opacity: Double) {
        let columns: (start: Int, end: Int)
        if draggingSourceID == segment.source,
           isResizingItem,
           let preview = draggingPreviewSchedule,
           let previewColumns = WeekRowPreviewLayout.columns(
            for: preview,
            weekStart: layout.weekStart
           ) {
            columns = previewColumns
        } else {
            columns = (segment.startColumn, segment.endColumn)
        }
        let isGhostMove = draggingSourceID == segment.source && !isResizingItem
        return (
            columnWidth * CGFloat(columns.end - columns.start + 1),
            columnWidth * CGFloat(columns.start),
            isGhostMove ? 0.32 : 1
        )
    }
}

private struct WeekRowDateCell: View {
    let date: CalendarDate
    let isToday: Bool
    let isSelected: Bool
    let isInSelection: Bool
    let overflow: Int
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onAction: (DayCellAction) -> Void
    let onRangeGesture: (WeekRowRangeGesture) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        let badge = CalendarDateBadgePresentation(
            date: date,
            isToday: isToday,
            isSelected: isSelected
        )
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    sendDayAction(for: .dateNumber)
                } label: {
                    let dayText = String(date.day)
                    Text(dayText)
                        .font(CalendarTheme.dateFont)
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(dateBadgeFill)
                        .clipShape(Capsule())
                        .overlay {
                            if badge.showsSelectionRing {
                                Capsule()
                                    .stroke(theme.selectionOutline, lineWidth: 1.5)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if badge.showsTodayDot {
                                Circle()
                                    .fill(theme.todayOutline)
                                    .frame(width: 4, height: 4)
                                    .overlay(Circle().stroke(theme.canvas, lineWidth: 0.5))
                                    .offset(y: 2)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(badge.accessibilityLabel)
                .accessibilityValue(badge.accessibilityValue)

                Spacer(minLength: 0)

                if overflow > 0 {
                    Button("还有 \(overflow) 项") {
                        sendDayAction(for: .overflow)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("\(date.month)月\(date.day)日，还有 \(overflow) 项，打开当天事项")
                }
            }
            .padding(.horizontal, CalendarTheme.cellPadding)
            .frame(height: WeekRowMetrics.dateHeaderHeight)
            GeometryReader { proxy in
                WeekRowEmptyRangeGestureSurface(
                    date: date,
                    rootOrigin: proxy.frame(
                        in: .named(CalendarInteractionCoordinateSpace.root)
                    ).origin,
                    onRangeGesture: onRangeGesture
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .background {
            Rectangle()
                .fill(isInSelection ? theme.rangePreviewFill : theme.canvas)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CalendarDateFramePreferenceKey.self,
                    value: [.init(
                        date: date,
                        frame: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                    )]
                )
            }
        }
        .overlay {
            Rectangle().stroke(theme.separator, lineWidth: 0.5)
            if isInSelection {
                Rectangle()
                    .inset(by: 2)
                    .stroke(
                        theme.rangePreviewOutline,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if dropCoordinator.dropTargetDate == date {
                Rectangle()
                    .fill(theme.dragPreviewFill)
                    .allowsHitTesting(false)
                    .overlay(Rectangle().inset(by: 1).stroke(theme.dragPreviewOutline, lineWidth: 1.5))
                    .overlay(alignment: .bottomLeading) {
                        Text("移到 \(date.month)月\(date.day)日")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .padding(4)
                    }
            }
        }
        .dropDestination(for: CalendarTransferPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            Task {
                try? await dropCoordinator.accept(payload, on: date)
            }
            return true
        } isTargeted: { isTargeted in
            dropCoordinator.setTargeted(isTargeted, date: date)
        }
    }

    private var dateBadgeFill: Color {
        if isSelected { return theme.selectionFill }
        if isToday { return theme.todayFill }
        return .clear
    }

    private func sendDayAction(for surface: WeekRowHitSurface) {
        guard let action = WeekRowHitRouting.dayAction(for: surface, date: date) else { return }
        onAction(action)
    }
}

private struct WeekRowSegmentBar: View {
    let segment: WeekRowSegmentPresentation
    let category: CalendarCategory?
    let weekStart: CalendarDate
    let columnWidth: CGFloat
    @ObservedObject var dropCoordinator: CalendarDropCoordinator
    let onItemGesture: (WeekRowItemGesture) -> Void
    let onCompletion: (CalendarCommand) -> Void
    let onOpenDetail: (ProjectedItem) -> Void
    var onDelete: ((ProjectedItem) -> Void)? = nil
    var onCopyToToday: ((ProjectedItem) -> Void)? = nil
    var onSetPriority: ((ProjectedItem, ItemPriority) -> Void)? = nil

    @State private var isItemDragging = false
    @State private var barFrameInRoot: CGRect = .zero

    var body: some View {
        CalendarItemRow(
            item: projectedItem,
            category: category,
            onCompletion: onCompletion,
            onOpenDetail: onOpenDetail,
            onDelete: onDelete.map { action in
                { action(projectedItem) }
            },
            onCopyToToday: onCopyToToday.map { action in
                { action(projectedItem) }
            },
            onSetPriority: onSetPriority.map { action in
                { action(projectedItem, $0) }
            },
            allowsSwipeToDelete: CalendarItemRowPlacement.monthGrid.allowsSwipeToDelete,
            accessibilityLabelOverride: segment.accessibilityLabel,
            accessibilityValueOverride: segment.accessibilityValue,
            continuesBefore: segment.continuesBefore,
            continuesAfter: segment.continuesAfter,
            showsLeadingHandle: segment.showsLeadingHandle,
            showsTrailingHandle: segment.showsTrailingHandle,
            leadingHandleAccessibility: segment.leadingHandleAccessibility,
            trailingHandleAccessibility: segment.trailingHandleAccessibility,
            timeTextStyle: .startOnly,
            onDropTransfer: untimedDropHandler
        )
        .accessibilityIdentifier(stableAccessibilityIdentifier)
        .accessibilityValue(segment.accessibilityValue)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WeekRowSegmentFramePreferenceKey.self,
                    value: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                )
            }
        }
        .onPreferenceChange(WeekRowSegmentFramePreferenceKey.self) { frame in
            barFrameInRoot = frame
        }
        // highPriority so edge resize isn't stolen by system .draggable / tap.
        // minimumDistance keeps short clicks free for open-detail.
        .highPriorityGesture(itemDragGesture)
    }

    private var itemDragGesture: some Gesture {
        DragGesture(
            minimumDistance: CalendarInteractionCoordinator.dragThreshold,
            coordinateSpace: .named(CalendarInteractionCoordinateSpace.root)
        )
        .onChanged { value in
            if !isItemDragging {
                isItemDragging = true
                let localX = value.startLocation.x - barFrameInRoot.minX
                guard let target = WeekRowItemHitRouting.dragTarget(
                    atX: localX,
                    width: max(barFrameInRoot.width, 1),
                    showsLeadingHandle: segment.showsLeadingHandle,
                    showsTrailingHandle: segment.showsTrailingHandle,
                    generousEdges: true
                ) else {
                    isItemDragging = false
                    return
                }
                onItemGesture(
                    .began(
                        dateAtLocalX(localX),
                        target,
                        segment.entry,
                        value.startLocation
                    )
                )
            }
            guard isItemDragging else { return }
            onItemGesture(.changed(value.location))
        }
        .onEnded { value in
            guard isItemDragging else { return }
            isItemDragging = false
            onItemGesture(.ended(value.location))
        }
    }

    private func dateAtLocalX(_ x: CGFloat) -> CalendarDate {
        guard columnWidth > 0 else {
            return weekStart.addingDays(segment.startColumn)
        }
        let localColumn = min(
            max(Int(floor(x / columnWidth)), 0),
            segment.endColumn - segment.startColumn
        )
        return weekStart.addingDays(segment.startColumn + localColumn)
    }

    private var untimedDropHandler: ((CalendarTransferPayload) -> Bool)? {
        guard case let .item(target) = projectedItem,
              UntimedItemReorder.isReorderable(target)
        else { return nil }
        let date = target.schedule.startDate
        let targetID = target.id
        return { payload in
            Task {
                let reordered = (try? await dropCoordinator.acceptUntimedReorder(
                    payload,
                    onto: targetID,
                    on: date
                )) ?? false
                if !reordered {
                    try? await dropCoordinator.accept(payload, on: date)
                }
            }
            return true
        }
    }

    private var projectedItem: ProjectedItem {
        switch segment.entry {
        case let .item(item):
            .item(item)
        case let .occurrence(occurrence):
            .occurrence(occurrence)
        }
    }

    private var stableAccessibilityIdentifier: String {
        switch segment.source {
        case let .item(id):
            "week-segment-item-\(id.uuidString)-\(segment.id.weekStart.year)-\(segment.id.weekStart.month)-\(segment.id.weekStart.day)"
        case let .occurrence(key):
            "week-segment-occurrence-\(key.seriesID.uuidString)-\(key.originalDate.year)-\(key.originalDate.month)-\(key.originalDate.day)-\(segment.id.weekStart.year)-\(segment.id.weekStart.month)-\(segment.id.weekStart.day)"
        }
    }
}

private struct WeekRowSegmentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}
