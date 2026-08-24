import CalendarDomain
import SwiftUI

enum WeekTimeGridMetrics {
    static let hourHeight: CGFloat = 48
    static let hourCount = 24
    static let gutterWidth: CGFloat = 48
    /// Compact all-day strip height (single row of chips).
    static let allDayChipHeight: CGFloat = 22
    static let allDayChipSpacing: CGFloat = 3
    static let allDayVerticalPadding: CGFloat = 6
    static let allDayMinHeight: CGFloat = 34
    /// Viewport shows this many chips; overflow scrolls (no +N truncate).
    static let allDayVisibleRows = 3
    /// Expanded viewport cap; beyond this the per-column scroll still applies.
    static let allDayExpandedRowLimit = 8
    static let dayHeaderHeight: CGFloat = 44
    static let gridCoordinateSpace = "week-timed-grid"

    static var gridHeight: CGFloat {
        CGFloat(hourCount) * hourHeight
    }

    /// First-appearance scroll target: one hour above "now", clamped, so the
    /// current time band sits just below the top edge instead of a fixed 08:00.
    static func initialAutoScrollHour(forNowMinuteOfDay minuteOfDay: Int) -> Int {
        let nowHour = min(max(minuteOfDay / 60, 0), hourCount - 1)
        return max(0, nowHour - 1)
    }

    static func yOffset(minute: Int) -> CGFloat {
        CGFloat(minute) / 60 * hourHeight
    }

    static func blockHeight(startMinute: Int, endMinute: Int) -> CGFloat {
        max(hourHeight * 0.35, yOffset(minute: endMinute - startMinute))
    }

    /// Fixed viewport for the given chip row count (scroll inside for more).
    static func allDaySectionHeight(rowCount: Int) -> CGFloat {
        let rows = max(1, rowCount)
        let content = CGFloat(rows) * allDayChipHeight + CGFloat(rows - 1) * allDayChipSpacing
        return max(allDayMinHeight, content + allDayVerticalPadding * 2)
    }

    /// Collapsed viewport height (`allDayVisibleRows`).
    static var allDaySectionHeight: CGFloat {
        allDaySectionHeight(rowCount: allDayVisibleRows)
    }
}

struct WeekView: View {
    let store: WorkspaceStore
    @ObservedObject var model: WeekViewModel
    let categories: [CalendarCategory]
    @Binding var hiddenCategoryIDs: Set<UUID>
    let onOpenDetail: (ProjectedItem) -> Void
    /// Create intent: start/end dates + optional times (nil times = all-day) + anchor in root space.
    let onCreate: (
        _ startDate: CalendarDate,
        _ endDate: CalendarDate,
        _ startTime: MinuteOfDay?,
        _ endTime: MinuteOfDay?,
        _ anchorFrame: CGRect
    ) -> Void
    /// Commit a move/resize from week-grid drag (same path as month-view mutations).
    let onCommitMutation: (PendingCalendarMutation) -> Void
    var onDelete: ((ProjectedItem) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var timedDrag: TimedDragState?
    @State private var allDayDrag: AllDayDragState?
    @State private var createSelection: CreateSelectionState?
    @State private var isAllDayExpanded = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var categoryByID: [UUID: CalendarCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            allDaySection
            Divider().overlay(theme.separator.opacity(0.7))
            timedScrollGrid
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(theme.canvas)
        .onChange(of: store.calendarState) { _, _ in
            model.update(
                state: store.calendarState,
                hiddenCategoryIDs: hiddenCategoryIDs,
                today: model.today
            )
            // Drop sticky drag preview only after the model has the new schedule —
            // clearing on gesture end caused a one-frame snap-back flash.
            timedDrag = nil
            allDayDrag = nil
            createSelection = nil
        }
        .onChange(of: hiddenCategoryIDs) { _, ids in
            model.update(state: store.calendarState, hiddenCategoryIDs: ids, today: model.today)
        }
    }

    // MARK: - All-day

    private var maxAllDayRowCount: Int {
        (0..<model.dayStarts.count).map { model.allDayItems(on: $0).count }.max() ?? 0
    }

    private var canExpandAllDay: Bool {
        maxAllDayRowCount > WeekTimeGridMetrics.allDayVisibleRows
    }

    private var allDayViewportRows: Int {
        isAllDayExpanded
            ? min(max(maxAllDayRowCount, 1), WeekTimeGridMetrics.allDayExpandedRowLimit)
            : WeekTimeGridMetrics.allDayVisibleRows
    }

    private var allDaySection: some View {
        let sectionHeight = WeekTimeGridMetrics.allDaySectionHeight(rowCount: allDayViewportRows)
        return GeometryReader { sectionProxy in
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 2) {
                    Text("全天")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Button {
                        withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.15)) {
                            isAllDayExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isAllDayExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .disabled(!canExpandAllDay)
                    .opacity(canExpandAllDay ? 1 : 0.35)
                    .accessibilityLabel(isAllDayExpanded ? "收起全天事项" : "展开全天事项")
                    .help(isAllDayExpanded ? "收起全天事项" : "展开全天事项")
                }
                .frame(width: WeekTimeGridMetrics.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 8)

                ForEach(Array(model.dayStarts.enumerated()), id: \.offset) { dayIndex, day in
                    let items = model.allDayItems(on: dayIndex)

                    GeometryReader { proxy in
                        ScrollView(.vertical, showsIndicators: items.count > WeekTimeGridMetrics.allDayVisibleRows) {
                            VStack(alignment: .leading, spacing: WeekTimeGridMetrics.allDayChipSpacing) {
                                ForEach(items) { item in
                                    allDayChip(
                                        entry: item.entry,
                                        dayIndex: dayIndex,
                                        sectionFrame: sectionProxy.frame(in: .global)
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 3)
                            .padding(.vertical, WeekTimeGridMetrics.allDayVerticalPadding)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard allDayDrag == nil else { return }
                            onCreate(
                                day,
                                day,
                                nil,
                                nil,
                                proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: sectionHeight)

                    if dayIndex < 6 {
                        Rectangle()
                            .fill(theme.separator.opacity(0.65))
                            .frame(width: 0.5)
                    }
                }
            }
            .frame(height: sectionHeight)
        }
        .frame(height: sectionHeight)
    }

    // MARK: - Timed grid

    private var timedScrollGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                GeometryReader { gridProxy in
                    let dayWidth = max(
                        0,
                        (gridProxy.size.width - WeekTimeGridMetrics.gutterWidth) / 7
                    )
                    let gridRootOrigin = gridProxy.frame(
                        in: .named(CalendarInteractionCoordinateSpace.root)
                    ).origin
                    ZStack(alignment: .topLeading) {
                        hourBackground
                        createSelectionLayer(
                            dayWidth: dayWidth,
                            gridRootOrigin: gridRootOrigin
                        )
                        createSelectionHighlight(dayWidth: dayWidth)
                        timedBlocksLayer
                    }
                    .frame(width: gridProxy.size.width, height: WeekTimeGridMetrics.gridHeight)
                    .coordinateSpace(name: WeekTimeGridMetrics.gridCoordinateSpace)
                }
                .frame(height: WeekTimeGridMetrics.gridHeight)
                .padding(.bottom, 12)
                .id("week-grid")
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .onAppear {
                // Scroll near "now" only on the first appearance. The consumed
                // flag lives on the week model, so recreating this view on a
                // month↔week switch never resets the user's scroll position.
                guard let hour = model.takeInitialAutoScrollHour(
                    nowMinuteOfDay: WeekViewModel.currentMinuteOfDay()
                ) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("hour-\(hour)", anchor: .top)
                    }
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private var hourBackground: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<WeekTimeGridMetrics.hourCount, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .frame(
                            width: WeekTimeGridMetrics.gutterWidth,
                            height: WeekTimeGridMetrics.hourHeight,
                            alignment: .topTrailing
                        )
                        .padding(.trailing, 6)
                        .offset(y: -6)
                        .id("hour-\(hour)")
                }
            }
            ForEach(0..<7, id: \.self) { dayIndex in
                ZStack {
                    if model.dayStarts.indices.contains(dayIndex),
                       model.dayStarts[dayIndex] == model.today {
                        theme.todayFill.opacity(0.14)
                    }
                    VStack(spacing: 0) {
                        ForEach(0..<WeekTimeGridMetrics.hourCount, id: \.self) { _ in
                            Rectangle()
                                .fill(theme.separator.opacity(0.45))
                                .frame(height: 0.5)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .frame(height: WeekTimeGridMetrics.hourHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if dayIndex < 6 {
                    Rectangle()
                        .fill(theme.separator.opacity(0.65))
                        .frame(width: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Empty-grid surface: drag across hour slots to select a timed band, then open create.
    private func createSelectionLayer(dayWidth: CGFloat, gridRootOrigin: CGPoint) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(WeekTimeGridMetrics.gridCoordinateSpace)
                )
                .onChanged { value in
                    guard timedDrag == nil, allDayDrag == nil else { return }
                    // Don't start a create selection from the hour gutter.
                    guard value.startLocation.x >= WeekTimeGridMetrics.gutterWidth else { return }

                    let originDay = WeekGridDrag.dayIndex(
                        atX: value.startLocation.x,
                        dayWidth: dayWidth
                    )
                    let originMinute = WeekGridDrag.minute(atY: value.startLocation.y)
                    let currentMinute = WeekGridDrag.minute(atY: value.location.y)
                    let isDragging = WeekGridCreateSelection.isRangeDrag(
                        from: value.startLocation,
                        to: value.location
                    )
                    let band = WeekGridCreateSelection.band(
                        originDayIndex: originDay,
                        originMinute: originMinute,
                        currentMinute: currentMinute,
                        isDragging: isDragging
                    )
                    createSelection = CreateSelectionState(
                        band: band,
                        isDragging: isDragging,
                        startLocation: value.startLocation
                    )
                }
                .onEnded { value in
                    defer { createSelection = nil }
                    guard timedDrag == nil, allDayDrag == nil else { return }
                    guard value.startLocation.x >= WeekTimeGridMetrics.gutterWidth else { return }

                    let originDay = WeekGridDrag.dayIndex(
                        atX: value.startLocation.x,
                        dayWidth: dayWidth
                    )
                    let originMinute = WeekGridDrag.minute(atY: value.startLocation.y)
                    let currentMinute = WeekGridDrag.minute(atY: value.location.y)
                    let isDragging = WeekGridCreateSelection.isRangeDrag(
                        from: value.startLocation,
                        to: value.location
                    )
                    let band = WeekGridCreateSelection.band(
                        originDayIndex: originDay,
                        originMinute: originMinute,
                        currentMinute: currentMinute,
                        isDragging: isDragging
                    )
                    guard let intent = try? WeekGridCreateSelection.intent(
                        dayStarts: model.dayStarts,
                        band: band
                    ) else { return }

                    let local = WeekGridCreateSelection.bandFrame(
                        band: band,
                        dayWidth: dayWidth
                    )
                    let anchor = local.offsetBy(dx: gridRootOrigin.x, dy: gridRootOrigin.y)
                    onCreate(
                        intent.day,
                        intent.endDate,
                        intent.startTime,
                        intent.endTime,
                        anchor
                    )
                }
            )
    }

    @ViewBuilder
    private func createSelectionHighlight(dayWidth: CGFloat) -> some View {
        if let selection = createSelection {
            let frame = WeekGridCreateSelection.bandFrame(
                band: selection.band,
                dayWidth: dayWidth
            )
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.rangePreviewFill.opacity(0.9))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.rangePreviewOutline, lineWidth: 1.5)
                }
                .overlay(alignment: .topLeading) {
                    Text(selectionTimeLabel(selection.band))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
        }
    }

    private func selectionTimeLabel(_ band: WeekGridCreateSelection.Band) -> String {
        func fmt(_ minute: Int) -> String {
            let clamped = min(24 * 60, max(0, minute))
            if clamped == 24 * 60 { return "24:00" }
            return String(format: "%02d:%02d", clamped / 60, clamped % 60)
        }
        return "\(fmt(band.startMinute))–\(fmt(band.endMinute))"
    }

    private var timedBlocksLayer: some View {
        GeometryReader { proxy in
            let dayWidth = max(0, (proxy.size.width - WeekTimeGridMetrics.gutterWidth) / 7)
            let gridOrigin = proxy.frame(in: .global).origin

            ForEach(model.timedBlocks()) { block in
                let display = displayTimedBlock(block)
                let x = WeekTimeGridMetrics.gutterWidth + CGFloat(display.dayIndex) * dayWidth + 2
                let y = WeekTimeGridMetrics.yOffset(minute: display.startMinute)
                let height = WeekTimeGridMetrics.blockHeight(
                    startMinute: display.startMinute,
                    endMinute: display.endMinute
                )
                timedChip(
                    entry: block.entry,
                    compactTime: CalendarItemRowPresentation.displayTimeText(
                        for: display.schedule ?? block.entry.schedule
                    ),
                    blockHeight: height,
                    isDragging: timedDrag?.entryID == ProjectedItem(entry: block.entry).id
                )
                .frame(width: max(24, dayWidth - 4), height: height, alignment: .topLeading)
                .position(x: x + (dayWidth - 4) / 2, y: y + height / 2)
                .opacity(timedDrag?.entryID == ProjectedItem(entry: block.entry).id ? 0.92 : 1)
                .highPriorityGesture(
                    timedDragGesture(
                        for: block,
                        dayWidth: dayWidth,
                        gridGlobalOrigin: gridOrigin
                    )
                )
            }
        }
    }

    private func displayTimedBlock(_ block: WeekTimedBlock) -> (
        dayIndex: Int,
        startMinute: Int,
        endMinute: Int,
        schedule: CalendarSchedule?
    ) {
        guard let drag = timedDrag,
              drag.entryID == ProjectedItem(entry: block.entry).id
        else {
            return (block.dayIndex, block.startMinute, block.endMinute, nil)
        }
        return (drag.dayIndex, drag.startMinute, drag.endMinute, drag.previewSchedule)
    }

    private func timedDragGesture(
        for block: WeekTimedBlock,
        dayWidth: CGFloat,
        gridGlobalOrigin: CGPoint
    ) -> some Gesture {
        let entryID = ProjectedItem(entry: block.entry).id
        let original = block.entry.schedule
        return DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let localX = value.location.x - gridGlobalOrigin.x
                let localY = value.location.y - gridGlobalOrigin.y
                let dayIdx = WeekGridDrag.dayIndex(atX: localX, dayWidth: dayWidth)
                let pointerMinute = WeekGridDrag.minute(atY: localY)

                if timedDrag == nil {
                    let startLocalY = value.startLocation.y - gridGlobalOrigin.y
                    let blockTop = WeekTimeGridMetrics.yOffset(minute: block.startMinute)
                    let blockHeight = WeekTimeGridMetrics.blockHeight(
                        startMinute: block.startMinute,
                        endMinute: block.endMinute
                    )
                    let kind = WeekGridDrag.kind(
                        localY: startLocalY - blockTop,
                        blockHeight: blockHeight
                    )
                    let grabMinute = WeekGridDrag.minute(atY: startLocalY)
                    timedDrag = TimedDragState(
                        entryID: entryID,
                        entry: block.entry,
                        kind: kind,
                        grabStartMinute: grabMinute,
                        dayIndex: dayIdx,
                        startMinute: block.startMinute,
                        endMinute: block.endMinute,
                        previewSchedule: original
                    )
                }

                guard var session = timedDrag, session.entryID == entryID else { return }
                let day = model.dayStarts[min(6, max(0, dayIdx))]
                if let preview = try? WeekGridDrag.previewTimed(
                    original: original,
                    kind: session.kind,
                    day: day,
                    grabStartMinute: session.grabStartMinute,
                    pointerMinute: pointerMinute
                ) {
                    session.previewSchedule = preview
                    session.dayIndex = dayIdx
                    // Visual band for same-day preview (overnight uses start day column).
                    let s = preview.startTime?.value ?? block.startMinute
                    var e = preview.endTime?.value ?? block.endMinute
                    if preview.endDate > preview.startDate {
                        e = preview.endTime?.value == 0 ? 24 * 60 : 24 * 60
                    }
                    session.startMinute = s
                    session.endMinute = max(s + WeekGridDrag.minDurationMinutes, e)
                    timedDrag = session
                }
            }
            .onEnded { _ in
                guard let session = timedDrag, session.entryID == entryID else {
                    timedDrag = nil
                    return
                }
                let preview = session.previewSchedule
                if preview == original {
                    timedDrag = nil
                    return
                }
                // Keep `timedDrag` until `store.state` changes so the block stays at the
                // drop position instead of flashing back to the old slot.
                onCommitMutation(PendingCalendarMutation(
                    source: session.entry,
                    operation: WeekGridDrag.operation(for: session.kind),
                    originalSchedule: original,
                    previewSchedule: preview
                ))
                let heldID = entryID
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    if timedDrag?.entryID == heldID {
                        timedDrag = nil
                    }
                }
            }
    }

    // MARK: - Chips

    @ViewBuilder
    private func allDayChip(
        entry: ProjectedEntry,
        dayIndex: Int,
        sectionFrame: CGRect
    ) -> some View {
        let item = ProjectedItem(entry: entry)
        let style = chipStyle(for: item)
        let isDragging = allDayDrag?.entryID == item.id
        HStack(spacing: 4) {
            Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(style.accent.opacity(0.85))
            ItemPriorityBadge(priority: item.priority)
            Text(entry.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(style.text)
        .background(style.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(item.completedAt == nil ? (isDragging ? 0.85 : 1) : CalendarTheme.completedItemOpacity(for: appearance))
        .contentShape(Rectangle())
        .frame(height: WeekTimeGridMetrics.allDayChipHeight)
        .offset(x: isDragging ? allDayDrag?.xOffset ?? 0 : 0)
        .help(entry.title)
        .highPriorityGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    let dayWidth = max(1, (sectionFrame.width - WeekTimeGridMetrics.gutterWidth) / 7)
                    let localX = value.location.x - sectionFrame.minX
                    let targetDay = WeekGridDrag.dayIndex(atX: localX, dayWidth: dayWidth)
                    let delta = targetDay - dayIndex
                    if allDayDrag == nil {
                        allDayDrag = AllDayDragState(
                            entryID: item.id,
                            entry: entry,
                            originDayIndex: dayIndex,
                            dayDelta: 0,
                            xOffset: 0
                        )
                    }
                    allDayDrag?.dayDelta = delta
                    allDayDrag?.xOffset = value.translation.width
                }
                .onEnded { _ in
                    guard let session = allDayDrag, session.entryID == item.id else {
                        allDayDrag = nil
                        return
                    }
                    let delta = session.dayDelta
                    guard delta != 0,
                          let preview = try? WeekGridDrag.previewAllDay(
                              original: entry.schedule,
                              dayDelta: delta
                          )
                    else {
                        allDayDrag = nil
                        return
                    }
                    // Keep preview offset until store reflects the move (no snap-back flash).
                    allDayDrag?.xOffset = CGFloat(delta) * max(
                        1,
                        (sectionFrame.width - WeekTimeGridMetrics.gutterWidth) / 7
                    )
                    onCommitMutation(PendingCalendarMutation(
                        source: entry,
                        operation: .move,
                        originalSchedule: entry.schedule,
                        previewSchedule: preview
                    ))
                    let heldID = item.id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        if allDayDrag?.entryID == heldID {
                            allDayDrag = nil
                        }
                    }
                }
        )
        .onTapGesture {
            guard allDayDrag == nil else { return }
            onOpenDetail(item)
        }
    }

    @ViewBuilder
    private func timedChip(
        entry: ProjectedEntry,
        compactTime: String?,
        blockHeight: CGFloat,
        isDragging: Bool
    ) -> some View {
        let item = ProjectedItem(entry: entry)
        let style = chipStyle(for: item)
        VStack(spacing: 0) {
            // Edge affordances
            Capsule()
                .fill(style.accent.opacity(0.55))
                .frame(width: 22, height: 3)
                .padding(.top, 3)
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(style.accent.opacity(0.85))
                    .onTapGesture {
                        // Completion via open detail for now; keep drag free.
                        onOpenDetail(item)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        ItemPriorityBadge(priority: item.priority)
                        if let compactTime {
                            Text(compactTime)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .opacity(0.8)
                        }
                    }
                    Text(entry.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
            Capsule()
                .fill(style.accent.opacity(0.55))
                .frame(width: 22, height: 3)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(style.text)
        .background(style.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(item.completedAt == nil ? 1 : CalendarTheme.completedItemOpacity(for: appearance))
        .overlay {
            if isDragging {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(style.accent.opacity(0.7), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard timedDrag == nil else { return }
            onOpenDetail(item)
        }
        .help(entry.title + " · 拖动移动，上下边缘调整时间")
    }

    private struct ChipStyle {
        let background: Color
        let text: Color
        let accent: Color
    }

    private func chipStyle(for item: ProjectedItem) -> ChipStyle {
        let hex = categoryByID[item.categoryID]?.colorHex ?? "#8C8F96"
        let roles = CalendarTheme.categoryItemRoles(
            hex,
            isCompleted: item.completedAt != nil,
            appearance: appearance
        )
        return ChipStyle(
            background: roles.map { CalendarTheme.categoryColor($0.background) }
                ?? CalendarTheme.itemBackground(CalendarTheme.categoryColor(hex), appearance: appearance),
            text: roles.map { CalendarTheme.categoryColor($0.text) } ?? theme.primaryText,
            accent: roles.map { CalendarTheme.categoryColor($0.accent) } ?? CalendarTheme.categoryColor(hex)
        )
    }
}

// MARK: - Drag session state

private struct TimedDragState: Equatable {
    let entryID: String
    let entry: ProjectedEntry
    let kind: WeekGridDrag.Kind
    let grabStartMinute: Int
    var dayIndex: Int
    var startMinute: Int
    var endMinute: Int
    var previewSchedule: CalendarSchedule
}

private struct AllDayDragState: Equatable {
    let entryID: String
    let entry: ProjectedEntry
    let originDayIndex: Int
    var dayDelta: Int
    var xOffset: CGFloat
}

private struct CreateSelectionState: Equatable {
    let band: WeekGridCreateSelection.Band
    let isDragging: Bool
    let startLocation: CGPoint
}
