import CalendarDomain
import SwiftUI
import WorkspaceDomain

enum MonthEmptyStateHintPolicy {
    static func shouldShow(phase: WorkspaceStorePhase, state: CalendarState) -> Bool {
        phase == .ready && state.items.isEmpty && state.recurrence.series.isEmpty
    }
}

struct MonthViewTodayRefreshPolicy {
    let now: () -> Date
    let calendar: Calendar

    static let calendarDayChangedNotification = Notification.Name.NSCalendarDayChanged

    var today: CalendarDate {
        CalendarDate.localDay(containing: now(), in: calendar.timeZone)
    }

    static func shouldRefresh(for scenePhase: ScenePhase) -> Bool {
        scenePhase == .active
    }

    static var live: MonthViewTodayRefreshPolicy {
        MonthViewTodayRefreshPolicy(now: Date.init, calendar: .autoupdatingCurrent)
    }
}

enum MonthViewTodayRefreshEvent {
    case calendarDayChanged
    case scenePhaseChanged(ScenePhase)
}

struct MonthViewTodayRefreshController {
    let policy: MonthViewTodayRefreshPolicy

    func handle(
        _ event: MonthViewTodayRefreshEvent,
        updateToday: (CalendarDate) -> Void
    ) {
        guard shouldRefresh(for: event) else { return }
        updateToday(policy.today)
    }

    private func shouldRefresh(for event: MonthViewTodayRefreshEvent) -> Bool {
        switch event {
        case .calendarDayChanged:
            true
        case let .scenePhaseChanged(scenePhase):
            MonthViewTodayRefreshPolicy.shouldRefresh(for: scenePhase)
        }
    }
}

private struct WeekStreamScrollRequest: Equatable {
    let id = UUID()
    let weekStart: CalendarDate
    let windowRevision: WeekStreamWindowRevision
    let animated: Bool
}

struct MonthViewInitialWeekStream: Equatable {
    let today: CalendarDate
    let weekStarts: [CalendarDate]
    let focusWeek: CalendarDate
    let monthTitleDate: CalendarDate
    let windowRevision: WeekStreamWindowRevision

    init(today: CalendarDate) {
        let stream = WeekStreamModel(centeredOn: today)
        self.today = today
        weekStarts = stream.weekStarts
        focusWeek = stream.focusWeek
        monthTitleDate = stream.monthTitleDate
        windowRevision = WeekStreamWindowRevision(weekStarts: stream.weekStarts)
    }
}

enum MonthQuickCreateRouting {
    static func presentation(for action: CalendarInteractionAction?) -> QuickCreatePresentation? {
        guard let action else { return nil }
        return QuickCreatePresentation(action: action)
    }
}

enum WeekStreamAutoScrollPlan: Equatable {
    case scroll(CalendarDate)
    case extendEarlier(thenScrollTo: CalendarDate)
    case extendLater(thenScrollTo: CalendarDate)
}

enum WeekStreamAutoScrollRouting {
    static func plan(
        cursorDate: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: [CalendarDate]
    ) -> WeekStreamAutoScrollPlan {
        let targetWeek = WeekStreamModel.weekStart(containing: cursorDate.addingDays(direction.dayDelta))
        guard !loadedWeekStarts.contains(targetWeek) else {
            return .scroll(targetWeek)
        }
        switch direction {
        case .earlier: return .extendEarlier(thenScrollTo: targetWeek)
        case .later: return .extendLater(thenScrollTo: targetWeek)
        }
    }
}

@MainActor
protocol WeekStreamAutoScrollDeferredCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol WeekStreamAutoScrollDeferrer: AnyObject {
    func deferToNextLayout(
        _ action: @escaping () -> Void
    ) -> any WeekStreamAutoScrollDeferredCancellation
}

@MainActor
final class WeekStreamAutoScrollExecutionDriver: ObservableObject {
    private let deferrer: any WeekStreamAutoScrollDeferrer
    private var pendingScroll: (any WeekStreamAutoScrollDeferredCancellation)?

    init(deferrer: any WeekStreamAutoScrollDeferrer = MainActorNextLayoutDeferrer()) {
        self.deferrer = deferrer
    }

    func execute(
        plan: WeekStreamAutoScrollPlan,
        visibleWeek: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: @escaping () -> [CalendarDate],
        extend: @escaping (CalendarInteractionAutoScrollDirection, CalendarDate) -> Void,
        scroll: @escaping (CalendarDate, CalendarInteractionAutoScrollDirection) -> Void
    ) {
        cancel()

        let targetWeek: CalendarDate
        switch plan {
        case let .scroll(week):
            targetWeek = week
        case let .extendEarlier(thenScrollTo: week):
            targetWeek = week
            extend(.earlier, visibleWeek)
        case let .extendLater(thenScrollTo: week):
            targetWeek = week
            extend(.later, visibleWeek)
        }

        guard plan.requiresWindowExtension else {
            scrollIfLoaded(
                targetWeek,
                direction: direction,
                loadedWeekStarts: loadedWeekStarts,
                scroll: scroll
            )
            return
        }

        pendingScroll = deferrer.deferToNextLayout { [weak self] in
            guard let self else { return }
            self.pendingScroll = nil
            self.scrollIfLoaded(
                targetWeek,
                direction: direction,
                loadedWeekStarts: loadedWeekStarts,
                scroll: scroll
            )
        }
    }

    func cancel() {
        pendingScroll?.cancel()
        pendingScroll = nil
    }

    private func scrollIfLoaded(
        _ targetWeek: CalendarDate,
        direction: CalendarInteractionAutoScrollDirection,
        loadedWeekStarts: () -> [CalendarDate],
        scroll: (CalendarDate, CalendarInteractionAutoScrollDirection) -> Void
    ) {
        guard loadedWeekStarts().contains(targetWeek) else { return }
        scroll(targetWeek, direction)
    }
}

private extension WeekStreamAutoScrollPlan {
    var requiresWindowExtension: Bool {
        switch self {
        case .scroll: false
        case .extendEarlier, .extendLater: true
        }
    }
}

@MainActor
private final class MainActorNextLayoutDeferrer: WeekStreamAutoScrollDeferrer {
    private final class Cancellation: WeekStreamAutoScrollDeferredCancellation {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    func deferToNextLayout(
        _ action: @escaping () -> Void
    ) -> any WeekStreamAutoScrollDeferredCancellation {
        let cancellation = Cancellation()
        Task { @MainActor in
            await Task.yield()
            guard !cancellation.isCancelled else { return }
            action()
        }
        return cancellation
    }
}

struct MonthView: View {
    let store: WorkspaceStore
    private let newItemRequest: WorkspaceNewItemRequest?
    private let consumeNewItemRequest: ((UUID, WorkspaceRoute) -> WorkspaceNewItemRequest?)?
    private let deepLinkRequest: WorkspaceDeepLinkRequest?
    private let consumeDeepLinkRequest: ((UUID, WorkspaceDeepLinkTarget) -> WorkspaceDeepLinkRequest?)?
    private let onOpenNote: (NoteID) -> Void
    private let todayRefreshPolicy: MonthViewTodayRefreshPolicy
    private let todayRefreshController: MonthViewTodayRefreshController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.workspaceActiveRoute) private var activeWorkspaceRoute
    @StateObject private var model: MonthViewModel
    @StateObject private var dropCoordinator: CalendarDropCoordinator
    @StateObject private var interactionCoordinator: CalendarInteractionCoordinator
    @StateObject private var autoScrollDriver: CalendarInteractionAutoScrollDriver
    @StateObject private var autoScrollExecutionDriver: WeekStreamAutoScrollExecutionDriver
    @StateObject private var weekStreamScrollCoordinator: WeekStreamScrollCoordinator
    @StateObject private var weekStreamRestoration: WeekStreamRestorationController
    @AppStorage("calendar.hiddenCategoryIDs") private var storedHiddenCategoryIDs = ""
    @AppStorage(CalendarAppearancePreference.storageKey)
    private var appearancePreferenceRaw = CalendarAppearancePreference.light.rawValue
    @AppStorage(CalendarPrimaryViewMode.storageKey)
    private var primaryViewModeRaw = CalendarPrimaryViewMode.month.rawValue
    @State private var hiddenCategoryIDs: Set<UUID> = []
    @StateObject private var weekModel: WeekViewModel
    @State private var quickCreatePresentation: QuickCreatePresentation?
    /// Forces a fresh create form each open (avoids SwiftUI reuse after first save).
    @State private var quickCreateSessionID = UUID()
    @State private var dateFrameMap = CalendarDateFrameMap(frames: [])
    @State private var lastEditorAnchorFrame: CGRect?
    @State private var quickCreateMeasuredContentSize = CGSize.zero
    @State private var selectedDayDrawerDate: CalendarDate?
    @State private var editorSession: ItemEditorConfiguration?
    @State private var categoryManagerPresentation: CategoryManagerPresentation?
    @State private var showProgressSummary = false
    @State private var pendingProgressSummaryItemID: String?
    @State private var recurringEditItem: ProjectedItem?
    @State private var deleteConfirmItem: ProjectedItem?
    @State private var actionError: String?
    @State private var actionRecoveryAction: WorkspaceRecoveryAction?
    @State private var recurringDropPresentation = RecurringDropPresentationController()
    @State private var requestedCenterRequest: WeekStreamScrollRequest?
    @State private var weekStreamCentering: WeekStreamCenteringCoordinator

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var motionPolicy: CalendarMotionPolicy {
        CalendarMotionPolicy(reduceMotion: accessibilityReduceMotion)
    }

    init(
        store: WorkspaceStore,
        todayRefreshPolicy: MonthViewTodayRefreshPolicy = .live,
        newItemRequest: WorkspaceNewItemRequest? = nil,
        consumeNewItemRequest: ((UUID, WorkspaceRoute) -> WorkspaceNewItemRequest?)? = nil,
        deepLinkRequest: WorkspaceDeepLinkRequest? = nil,
        consumeDeepLinkRequest: ((UUID, WorkspaceDeepLinkTarget) -> WorkspaceDeepLinkRequest?)? = nil,
        onOpenNote: @escaping (NoteID) -> Void = { _ in }
    ) {
        self.store = store
        self.newItemRequest = newItemRequest
        self.consumeNewItemRequest = consumeNewItemRequest
        self.deepLinkRequest = deepLinkRequest
        self.consumeDeepLinkRequest = consumeDeepLinkRequest
        self.onOpenNote = onOpenNote
        self.todayRefreshPolicy = todayRefreshPolicy
        todayRefreshController = MonthViewTodayRefreshController(policy: todayRefreshPolicy)
        let initialWeekStream = MonthViewInitialWeekStream(today: todayRefreshPolicy.today)
        _model = StateObject(wrappedValue: MonthViewModel(
            centeredOn: initialWeekStream.today,
            state: store.calendarState,
            hiddenCategoryIDs: [],
            today: initialWeekStream.today
        ))
        _dropCoordinator = StateObject(wrappedValue: CalendarDropCoordinator(store: store))
        _interactionCoordinator = StateObject(wrappedValue: CalendarInteractionCoordinator())
        _autoScrollDriver = StateObject(wrappedValue: CalendarInteractionAutoScrollDriver())
        _autoScrollExecutionDriver = StateObject(wrappedValue: WeekStreamAutoScrollExecutionDriver())
        let restoration = WeekStreamRestorationController()
        _weekStreamRestoration = StateObject(wrappedValue: restoration)
        _weekStreamScrollCoordinator = StateObject(wrappedValue: WeekStreamScrollCoordinator {
            [weak restoration] adjustment in
            restoration?.recordAppliedAdjustment(adjustment)
        })
        var initialCentering = WeekStreamCenteringCoordinator()
        _ = initialCentering.begin(
            weekStart: initialWeekStream.focusWeek,
            windowRevision: initialWeekStream.windowRevision
        )
        _weekStreamCentering = State(initialValue: initialCentering)
        _weekModel = StateObject(wrappedValue: WeekViewModel(
            weekStart: initialWeekStream.focusWeek,
            today: todayRefreshPolicy.today,
            state: store.calendarState,
            hiddenCategoryIDs: []
        ))
    }

    private var primaryViewMode: CalendarPrimaryViewMode {
        CalendarPrimaryViewMode(rawValue: primaryViewModeRaw) ?? .month
    }

    var body: some View {
        dialogsAndOverlays
            .alert("日历提示", isPresented: alertPresented) {
                if actionRecoveryAction != nil {
                    Button("继续恢复", action: retryActionRecovery)
                }
                Button("知道了", role: .cancel) {
                    actionError = nil
                    actionRecoveryAction = nil
                }
            } message: {
                Text(actionError ?? "")
            }
    }

    private var dialogsAndOverlays: some View {
        lifecycleBound
            .confirmationDialog(
                "修改重复事项",
                isPresented: recurringDropConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("仅本次") { resolveRecurringDrop(scope: .onlyThis) }
                Button("本次及以后") { resolveRecurringDrop(scope: .thisAndFuture) }
                Button("取消", role: .cancel) { cancelRecurringDropConfirmation() }
            } message: {
                Text("请选择这次修改影响的范围")
            }
            .confirmationDialog(
                "编辑重复事项",
                isPresented: recurringEditPresented,
                titleVisibility: .visible
            ) {
                Button("仅本次") { confirmRecurringEdit(scope: .onlyThis) }
                Button("本次及以后") { confirmRecurringEdit(scope: .thisAndFuture) }
                Button("取消", role: .cancel) { recurringEditItem = nil }
            } message: {
                Text("请选择这次编辑影响的范围")
            }
            .confirmationDialog(
                "删除此事项？",
                isPresented: deleteConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { confirmDeleteItem() }
                Button("取消", role: .cancel) { deleteConfirmItem = nil }
            }
            .environment(\.openCategoryManager, OpenCategoryManagerAction { categoryID in
                categoryManagerPresentation = CategoryManagerPresentation(
                    initialCategoryID: categoryID
                )
            })
            .overlay(alignment: .trailing) { dayDrawerOverlay }
            .overlay { editorOverlay }
            .overlay { quickCreateOverlay }
            .overlay { itemDragPreviewOverlay }
            .overlay { categoryManagerOverlay }
    }

    /// Floating item chip under the pointer while month-row move/resize is active.
    @ViewBuilder
    private var itemDragPreviewOverlay: some View {
        if interactionCoordinator.isMovingItem,
           let entry = interactionCoordinator.dragSourceEntry,
           let pointer = interactionCoordinator.dragPreviewPointer
                ?? interactionCoordinator.latestPointer
        {
            ItemDragPreviewChip.make(
                entry: entry,
                category: store.calendarState.categories[entry.categoryID]
            )
            // Lift slightly above the cursor so the target date stays readable.
            // No animation — follow the pointer 1:1 for a solid “holding the card” feel.
            .position(x: pointer.x, y: pointer.y - 14)
            .allowsHitTesting(false)
        }
    }

    private var lifecycleBound: some View {
        calendarChrome
            .background(theme.canvas)
            .foregroundStyle(theme.primaryText)
            .tint(theme.controlAccent)
            .transaction { transaction in
                if accessibilityReduceMotion {
                    transaction.disablesAnimations = true
                }
            }
            .coordinateSpace(name: CalendarInteractionCoordinateSpace.root)
            .onAppear {
                hiddenCategoryIDs = CategoryFilterView.decode(storedHiddenCategoryIDs)
                refreshProjection()
                consumeCalendarNewItemRequest(newItemRequest)
                consumeCalendarDeepLinkRequest(deepLinkRequest)
            }
            .onChange(of: newItemRequest) { _, request in
                consumeCalendarNewItemRequest(request)
            }
            .onChange(of: deepLinkRequest) { _, request in
                consumeCalendarDeepLinkRequest(request)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: MonthViewTodayRefreshPolicy.calendarDayChangedNotification
            )) { _ in
                refreshToday(for: .calendarDayChanged)
            }
            .onChange(of: scenePhase) { _, newPhase in
                refreshToday(for: .scenePhaseChanged(newPhase))
            }
            .onChange(of: activeWorkspaceRoute) { _, route in
                guard route != .calendar else { return }
                selectedDayDrawerDate = nil
                quickCreatePresentation = nil
                editorSession = nil
                showProgressSummary = false
                categoryManagerPresentation = nil
            }
            .onChange(of: showProgressSummary) { _, isPresented in
                guard !isPresented,
                      let itemID = pendingProgressSummaryItemID else { return }
                pendingProgressSummaryItemID = nil
                guard let item = model.projectedItem(withID: itemID) else { return }
                openEditor(for: item)
            }
            .onChange(of: store.calendarState) { _, _ in
                refreshProjection()
                weekModel.update(
                    state: store.calendarState,
                    hiddenCategoryIDs: hiddenCategoryIDs,
                    today: model.today
                )
            }
            .onChange(of: hiddenCategoryIDs) { _, _ in
                refreshProjection()
                weekModel.update(
                    state: store.calendarState,
                    hiddenCategoryIDs: hiddenCategoryIDs,
                    today: model.today
                )
            }
            .onChange(of: primaryViewModeRaw) { _, raw in
                // A date drawer is a temporary inspection layer. Carrying it
                // into another calendar mode squeezes the new primary view and
                // leaves two competing contexts on screen.
                selectedDayDrawerDate = nil
                quickCreatePresentation = nil
                editorSession = nil
                switch CalendarPrimaryViewMode(rawValue: raw) ?? .month {
                case .week:
                    weekModel.focus(on: model.monthToWeekAnchorDate())
                    weekModel.update(
                        state: store.calendarState,
                        hiddenCategoryIDs: hiddenCategoryIDs,
                        today: model.today
                    )
                case .month:
                    // Month's ScrollView is recreated at weekStarts[0] (~1–3 years
                    // back). Adopt the week we just left and re-arm centering
                    // before the first viewport frames can steal focus.
                    model.reveal(weekContaining: weekModel.weekStart)
                    requestCentering(on: model.focusWeek, animated: false)
                }
            }
            .onChange(of: storedHiddenCategoryIDs) { _, encoded in
                hiddenCategoryIDs = CategoryFilterView.decode(encoded)
            }
            .onChange(of: dropCoordinator.pendingRecurringDrop) { _, pendingDrop in
                recurringDropPresentation.pendingDropDidChange(hasPendingDrop: pendingDrop != nil)
            }
            .onPreferenceChange(QuickCreateCardSizePreferenceKey.self) { size in
                guard size.width > 0, size.height > 0 else { return }
                quickCreateMeasuredContentSize = size
            }
    }

    @ViewBuilder
    private var calendarChrome: some View {
        VStack(spacing: 0) {
            toolbar
            if primaryViewMode == .month {
                weekdayHeader
                GeometryReader { proxy in
                    weekStream(viewportBounds: proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root)))
                }
            } else {
                // GeometryReader gives a hard height budget. ScrollView otherwise keeps a
                // min height ≈ 24×hourHeight and the day header is pushed down the window.
                GeometryReader { proxy in
                    let headerH = WeekTimeGridMetrics.dayHeaderHeight
                    VStack(spacing: 0) {
                        weekDayHeader
                            .frame(width: proxy.size.width, height: headerH)
                        WeekView(
                            store: store,
                            model: weekModel,
                            categories: orderedCategories,
                            hiddenCategoryIDs: $hiddenCategoryIDs,
                            onOpenDetail: { openEditor(for: $0) },
                            onCreate: { startDate, endDate, startTime, endTime, anchorFrame in
                                openQuickCreate(
                                    on: startDate,
                                    endDate: endDate,
                                    startTime: startTime,
                                    endTime: endTime,
                                    anchorFrame: anchorFrame
                                )
                            },
                            onCommitMutation: { pending in
                                commitWeekMutation(pending)
                            },
                            onDelete: { requestDelete($0) },
                            onCopyToToday: { copyItemToToday($0) }
                        )
                        .frame(
                            width: proxy.size.width,
                            height: max(0, proxy.size.height - headerH)
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var dayDrawerOverlay: some View {
        if let date = selectedDayDrawerDate {
            DayDrawerView(
                date: date,
                store: store,
                categories: store.calendarState.categories,
                hiddenCategoryIDs: hiddenCategoryIDs,
                onClose: {
                    withAnimation(motionPolicy.overlayAnimation) {
                        selectedDayDrawerDate = nil
                    }
                },
                onQuickCreate: { openQuickCreate(on: $0) },
                onOpenDetail: { openEditor(for: $0) },
                onDelete: { requestDelete($0) },
                onCopyToToday: { copyItemToToday($0) },
                dropCoordinator: dropCoordinator
            )
            .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder
    private var editorOverlay: some View {
        if let session = editorSession {
            ZStack {
                dismissScrim(action: { editorSession = nil })
                ItemEditForm(
                    configuration: session,
                    store: store,
                    categories: orderedCategories,
                    onOpenNote: { noteID in
                        editorSession = nil
                        onOpenNote(noteID)
                    },
                    onCancel: { editorSession = nil },
                    onSaved: { editorSession = nil },
                    onCopyToToday: { item in
                        editorSession = nil
                        copyItemToToday(item)
                    },
                    onManageCategories: presentCategoryManager
                )
                .id(session.id)
                .background(theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.subtleBorder, lineWidth: 1)
                }
                .shadow(color: theme.subtleShadow.opacity(0.22), radius: 16, y: 6)
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityIdentifier("item-edit-overlay-card")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var categoryManagerOverlay: some View {
        if categoryManagerPresentation != nil {
            ZStack {
                dismissScrim(action: { categoryManagerPresentation = nil })
                CategoryManagerView(
                    store: store,
                    initialCategoryID: categoryManagerPresentation?.initialCategoryID,
                    onClose: { categoryManagerPresentation = nil }
                )
                .frame(width: 680)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: theme.subtleShadow.opacity(0.22), radius: 16, y: 6)
                .preferredColorScheme(colorScheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var quickCreateOverlay: some View {
        // Only mount when presenting — a permanent empty GeometryReader can steal hits.
        if let presentation = quickCreatePresentation {
            GeometryReader { proxy in
                let windowBounds = proxy.frame(in: .named(CalendarInteractionCoordinateSpace.root))
                let overlayPresentation = QuickCreateOverlayPresentation(
                    presentation: presentation,
                    measuredContentSize: quickCreateMeasuredContentSize,
                    anchorFrame: resolvedEditorAnchorFrame(
                        for: presentation.anchorDate,
                        windowBounds: windowBounds
                    ),
                    windowBounds: windowBounds
                )
                ZStack {
                    dismissScrim(action: dismissQuickCreate)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    QuickCreatePopover(
                        presentation: presentation,
                        categories: orderedCategories,
                        store: store,
                        availableWidth: overlayPresentation.placement.frame.width,
                        maximumContentHeight: overlayPresentation.contentLayout.maximumHeight,
                        onClose: dismissQuickCreate,
                        onManageCategories: presentCategoryManager
                    )
                    .id(quickCreateSessionID)
                    .frame(width: overlayPresentation.placement.frame.width)
                    .background(theme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.subtleBorder, lineWidth: 1)
                    }
                    .shadow(color: theme.subtleShadow.opacity(0.20), radius: 14, y: 5)
                    .position(
                        x: overlayPresentation.placement.frame.midX,
                        y: overlayPresentation.placement.frame.midY
                    )
                    .accessibilityIdentifier("quick-create-overlay-card")
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Title — left, calm
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryViewMode == .month ? monthTitle : weekModel.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                if primaryViewMode == .month,
                   MonthEmptyStateHintPolicy.shouldShow(phase: store.phase, state: store.calendarState) {
                    Text("点击日期开始创建")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer(minLength: 16)

            // Controls — grouped, equal visual weight
            HStack(spacing: 8) {
                viewModeControl
                navigationCluster
                progressSummaryButton
                categoryControl
                appearanceToggle
            }
            .disabled(store.phase != .ready)
        }
        .padding(.horizontal, 16)
        .frame(height: CalendarTheme.toolbarHeight)
        .sheet(isPresented: $showProgressSummary) {
            ProgressSummaryView(
                store: store,
                period: primaryViewMode == .week ? .week : .month,
                today: model.today,
                hiddenCategoryIDs: hiddenCategoryIDs,
                onOpenItem: { itemID in
                    pendingProgressSummaryItemID = itemID
                    showProgressSummary = false
                },
                onClose: { showProgressSummary = false }
            )
            .padding(20)
            .background(theme.canvas.opacity(0.001)) // sheet chrome host
        }
    }

    /// Deterministic local review for the visible period.
    private var progressSummaryButton: some View {
        let label = primaryViewMode == .week ? "本周回顾" : "本月回顾"
        return Button {
            showProgressSummary = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                theme.subtleBorder.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看从\(primaryViewMode == .week ? "本周" : "本月")第一天到今天的完成情况")
        .accessibilityLabel(label)
    }

    /// 月 / 周 — compact pill, no external “视图” label.
    private var viewModeControl: some View {
        HStack(spacing: 0) {
            ForEach(CalendarPrimaryViewMode.allCases) { mode in
                let selected = primaryViewMode == mode
                Button {
                    primaryViewModeRaw = mode.rawValue
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                        .frame(width: 36, height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.controlAccent.opacity(0.28))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.help)
            }
        }
        .padding(2)
        .background(
            theme.subtleBorder.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视图")
    }

    /// ⟨ 今天 ⟩ as one control group.
    private var navigationCluster: some View {
        HStack(spacing: 0) {
            toolbarIconHit(
                systemName: "chevron.left",
                help: primaryViewMode == .month ? "上个月" : "上一周"
            ) {
                if primaryViewMode == .month {
                    navigateToPreviousMonth()
                } else {
                    weekModel.goToPreviousWeek()
                }
            }

            Button {
                if primaryViewMode == .month {
                    navigateToToday()
                } else {
                    weekModel.goToToday()
                }
            } label: {
                Text("今天")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .frame(height: 26)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到今天")

            toolbarIconHit(
                systemName: "chevron.right",
                help: primaryViewMode == .month ? "下个月" : "下一周"
            ) {
                if primaryViewMode == .month {
                    navigateToNextMonth()
                } else {
                    weekModel.goToNextWeek()
                }
            }
        }
        .padding(2)
        .background(
            theme.subtleBorder.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// Filter + manage in one menu (was two separate noisy controls).
    private var categoryControl: some View {
        let filtered = !hiddenCategoryIDs.isEmpty
        return Menu {
            CategoryFilterView(
                categories: orderedCategories,
                hiddenCategoryIDs: $hiddenCategoryIDs
            )
            Divider()
            Button("管理分类…") {
                categoryManagerPresentation = CategoryManagerPresentation(initialCategoryID: nil)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .medium))
                Text("分类")
                    .font(.system(size: 12, weight: .medium))
                if filtered {
                    Circle()
                        .fill(theme.controlAccent)
                        .frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.65)
            }
            .foregroundStyle(filtered ? theme.controlAccent : theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                theme.subtleBorder.opacity(filtered ? 0.32 : 0.22),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(filtered ? "分类筛选（已隐藏 \(hiddenCategoryIDs.count) 个）" : "分类筛选与管理")
    }

    private func toolbarIconHit(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var weekDayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: WeekTimeGridMetrics.gutterWidth)
            ForEach(Array(weekModel.dayStarts.enumerated()), id: \.offset) { _, day in
                GeometryReader { proxy in
                    VStack(spacing: 1) {
                        Text(weekdayLabel(for: day))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        Text("\(day.day)")
                            .font(.system(size: 14, weight: day == weekModel.today ? .bold : .semibold))
                            .foregroundStyle(day == weekModel.today ? theme.controlAccent : theme.primaryText)
                            .frame(width: 26, height: 26)
                            .background {
                                if day == weekModel.today {
                                    Circle().fill(theme.todayFill)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openQuickCreate(
                            on: day,
                            anchorFrame: proxy.frame(
                                in: .named(CalendarInteractionCoordinateSpace.root)
                            )
                        )
                    }
                }
            }
        }
        .frame(height: WeekTimeGridMetrics.dayHeaderHeight)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private func weekdayLabel(for day: CalendarDate) -> String {
        switch day.weekday {
        case .monday: "一"
        case .tuesday: "二"
        case .wednesday: "三"
        case .thursday: "四"
        case .friday: "五"
        case .saturday: "六"
        case .sunday: "日"
        }
    }

    private var appearancePreference: CalendarAppearancePreference {
        CalendarAppearancePreference(rawValue: appearancePreferenceRaw) ?? .light
    }

    /// One click: light ↔ dark (no menu, no “follow system”).
    private var appearanceToggle: some View {
        Button {
            let next = appearancePreference.toggled(renderedAs: colorScheme)
            appearancePreferenceRaw = next.rawValue
            CalendarAppearancePreference.applyToApplication(next)
        } label: {
            Image(systemName: appearancePreference.toggleSymbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    theme.subtleBorder.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(appearancePreference == .dark ? "切换到浅色" : "切换到深色")
        .accessibilityLabel("切换主题")
        .accessibilityValue(appearancePreference == .dark ? "深色" : "浅色")
        .accessibilityIdentifier("appearance-preference-toggle")
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { weekday in
                Text(weekday)
                    .font(CalendarTheme.dateFont)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarTheme.weekdayHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator).frame(height: 0.5)
        }
    }

    private var monthTitle: String {
        "\(model.monthTitleDate.year)年\(model.monthTitleDate.month)月"
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: {
                recurringDropPresentation.isErrorPresented || actionError != nil
            },
            set: { isPresented in
                guard !isPresented else { return }
                _ = recurringDropPresentation.acknowledgeError(
                    hasPendingDrop: dropCoordinator.pendingRecurringDrop != nil
                )
            }
        )
    }

    private var recurringDropConfirmationPresented: Binding<Bool> {
        Binding(
            get: { recurringDropPresentation.isConfirmationPresented },
            set: { isPresented in
                guard !isPresented else { return }
                requestRecurringDropConfirmationDismissal()
            }
        )
    }

    private var recurringEditPresented: Binding<Bool> {
        Binding(
            get: { recurringEditItem != nil },
            set: { if !$0 { recurringEditItem = nil } }
        )
    }

    private var deleteConfirmPresented: Binding<Bool> {
        Binding(
            get: { deleteConfirmItem != nil },
            set: { if !$0 { deleteConfirmItem = nil } }
        )
    }

    private var orderedCategories: [CalendarCategory] {
        store.calendarState.categories.values.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
    }

    private func handle(_ action: DayCellAction) {
        switch action {
        case let .openDay(date):
            model.selectedDate = date
            withAnimation(motionPolicy.overlayAnimation) {
                selectedDayDrawerDate = date
            }
        case let .quickCreate(date):
            openQuickCreate(on: date)
        case let .openItem(id):
            if let item = model.projectedItem(withID: id) {
                openEditor(for: item)
            }
        }
    }

    private func consumeCalendarNewItemRequest(_ request: WorkspaceNewItemRequest?) {
        guard let request,
              request.route == .calendar,
              consumeNewItemRequest?(request.id, .calendar) != nil
        else {
            return
        }

        guard let date = CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: selectedDayDrawerDate,
            selectedDate: model.selectedDate,
            today: model.today,
            isQuickCreatePresented: quickCreatePresentation != nil,
            isItemEditorPresented: editorSession != nil
        ) else {
            return
        }
        openQuickCreate(on: date)
    }

    private func consumeCalendarDeepLinkRequest(_ request: WorkspaceDeepLinkRequest?) {
        guard let request else { return }
        let configuration: ItemEditorConfiguration
        switch request.target {
        case let .calendarItem(itemID):
            guard let item = store.calendarState.items[itemID] else { return }
            configuration = .oneOff(item: item)
        case let .calendarOccurrence(key):
            guard let series = store.calendarState.recurrence.series[key.seriesID],
                  let occurrence = CalendarDeepLinkTargetResolver.occurrence(
                    for: key,
                    calendar: store.calendarState
                  ) else { return }
            configuration = .occurrence(series: series, occurrence: occurrence, scope: .onlyThis)
        case let .calendarSeries(seriesID):
            guard let series = store.calendarState.recurrence.series[seriesID],
                  let occurrence = CalendarDeepLinkTargetResolver.representativeOccurrence(
                    for: seriesID,
                    calendar: store.calendarState,
                    today: model.today
                  ) else { return }
            configuration = .occurrence(series: series, occurrence: occurrence, scope: .thisAndFuture)
        case .note, .inspiration:
            return
        }
        guard consumeDeepLinkRequest?(request.id, request.target) != nil else { return }
        selectedDayDrawerDate = nil
        quickCreatePresentation = nil
        withAnimation(motionPolicy.overlayAnimation) {
            editorSession = configuration
        }
    }

    private func openEditor(for item: ProjectedItem) {
        selectedDayDrawerDate = nil
        quickCreatePresentation = nil
        switch item {
        case .item:
            if let config = ItemActions.editorConfiguration(
                for: item,
                seriesLookup: { store.calendarState.recurrence.series[$0] },
                scope: .onlyThis
            ) {
                withAnimation(motionPolicy.overlayAnimation) {
                    editorSession = config
                }
            }
        case .occurrence:
            recurringEditItem = item
        }
    }

    private func confirmRecurringEdit(scope: SeriesScope) {
        guard let item = recurringEditItem else { return }
        recurringEditItem = nil
        if let config = ItemActions.editorConfiguration(
            for: item,
            seriesLookup: { store.calendarState.recurrence.series[$0] },
            scope: scope
        ) {
            selectedDayDrawerDate = nil
            quickCreatePresentation = nil
            withAnimation(motionPolicy.overlayAnimation) {
                editorSession = config
            }
        }
    }

    private func presentCategoryManager(categoryID: UUID?) {
        categoryManagerPresentation = CategoryManagerPresentation(initialCategoryID: categoryID)
    }

    private func requestDelete(_ item: ProjectedItem) {
        deleteConfirmItem = item
    }

    private func copyItemToToday(_ item: ProjectedItem) {
        actionError = nil
        actionRecoveryAction = nil
        guard store.phase == .ready else {
            actionError = "日历尚未准备好，当前操作未保存。"
            return
        }
        let today = todayRefreshPolicy.today
        Task {
            do {
                let presentation = WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(
                        try ItemActions.copyToDay(item, day: today, now: Date()),
                        undoLabel: "已复制到当天"
                    )
                )
                receiveActionPresentation(presentation)
                if presentation.allowsDismissal {
                    revealCopiedItem(on: today)
                }
            } catch {
                actionError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func revealCopiedItem(on today: CalendarDate) {
        if primaryViewMode == .month {
            navigateToToday()
        } else {
            weekModel.goToToday()
        }
        if selectedDayDrawerDate != nil {
            selectedDayDrawerDate = today
        }
    }

    private func confirmDeleteItem() {
        guard let item = deleteConfirmItem else { return }
        deleteConfirmItem = nil
        sendItemAction(ItemActions.deleteCommand(for: item), undoLabel: "已删除事项")
    }

    private func sendItemAction(_ command: CalendarCommand, undoLabel: String) {
        actionError = nil
        actionRecoveryAction = nil
        guard store.phase == .ready else {
            actionError = "日历尚未准备好，当前操作未保存。"
            return
        }
        Task {
            do {
                receiveActionPresentation(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: undoLabel)
                ))
            } catch {
                actionError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func sendCompletion(_ command: CalendarCommand) {
        actionError = nil
        actionRecoveryAction = nil
        guard store.phase == .ready else {
            actionError = "日历尚未准备好，完成状态没有保存。"
            return
        }
        Task {
            do {
                receiveActionPresentation(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: "已更新完成状态")
                ))
            } catch {
                actionError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func receiveActionPresentation(_ presentation: WorkspaceMutationPresentation) {
        actionError = presentation.message
        actionRecoveryAction = presentation.recoveryAction
    }

    private func retryActionRecovery() {
        guard let actionRecoveryAction else { return }
        Task { @MainActor in
            receiveActionPresentation(await WorkspaceMutationOutcomePresenter.retry(actionRecoveryAction, in: store))
        }
    }

    private func resolveRecurringDrop(scope: SeriesScope) {
        guard recurringDropPresentation.beginScopeSelection() else { return }
        guard let resolution = dropCoordinator.beginResolution(scope: scope) else {
            recurringDropPresentation.scopeSelectionCaptureFailed(
                hasPendingDrop: dropCoordinator.pendingRecurringDrop != nil
            )
            if dropCoordinator.pendingRecurringDrop == nil {
                interactionCoordinator.completePendingMutation()
            }
            return
        }
        Task {
            do {
                try await dropCoordinator.submit(resolution)
                recurringDropPresentation.resolutionSucceeded()
                interactionCoordinator.completePendingMutation()
            } catch {
                recurringDropPresentation.resolutionFailed()
            }
        }
    }

    private func requestRecurringDropConfirmationDismissal() {
        guard recurringDropPresentation.requestConfirmationDismissal() else { return }
        Task { @MainActor in
            await Task.yield()
            guard recurringDropPresentation.settleConfirmationDismissal() else { return }
            dropCoordinator.cancel()
            interactionCoordinator.completePendingMutation()
        }
    }

    private func cancelRecurringDropConfirmation() {
        guard recurringDropPresentation.cancelConfirmation() else { return }
        dropCoordinator.cancel()
        interactionCoordinator.completePendingMutation()
    }

    private func refreshProjection() {
        refreshProjection(today: todayRefreshPolicy.today)
    }

    private func refreshToday(for event: MonthViewTodayRefreshEvent) {
        todayRefreshController.handle(event) { today in
            refreshProjection(today: today)
        }
    }

    private func refreshProjection(today: CalendarDate) {
        model.update(
            state: store.calendarState,
            hiddenCategoryIDs: hiddenCategoryIDs,
            today: today
        )
    }

    private func navigateToPreviousMonth() {
        model.moveWeekStreamFocus(to: .previousLogicalMonth)
        requestCentering(on: model.focusWeek)
    }

    private func navigateToNextMonth() {
        model.moveWeekStreamFocus(to: .nextLogicalMonth)
        requestCentering(on: model.focusWeek)
    }

    private func navigateToToday() {
        model.moveWeekStreamFocus(to: .today(todayRefreshPolicy.today))
        requestCentering(on: model.focusWeek)
    }

    private func requestCentering(on weekStart: CalendarDate, animated: Bool = true) {
        weekStreamRestoration.cancel()
        weekStreamScrollCoordinator.invalidateQueuedCorrection()
        let revision = WeekStreamWindowRevision(weekStarts: model.weekStarts)
        // Arm the coordinator immediately. The month ScrollView is often created
        // *after* this call, so `onChange(of: requestedCenterRequest)` may never
        // fire; `onAppear` reads `pendingRequest` instead.
        _ = weekStreamCentering.begin(
            weekStart: weekStart,
            windowRevision: revision
        )
        requestedCenterRequest = .init(
            weekStart: weekStart,
            windowRevision: revision,
            animated: animated
        )
    }

    private func weekStream(viewportBounds: CGRect) -> some View {
        let viewportHeight = viewportBounds.height
        let windowRevision = WeekStreamWindowRevision(weekStarts: model.weekStarts)
        let layouts = Dictionary(uniqueKeysWithValues: model.weekLayouts(
            laneCapacity: WeekRowMetrics.itemCapacity(height: WeekRowMetrics.defaultHeight)
        ).map { ($0.weekStart, $0) })

        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.weekStarts, id: \.self) { weekStart in
                        if let layout = layouts[weekStart] {
                            WeekRowView(
                                layout: layout,
                                today: model.today,
                                selectedDate: model.selectedDate,
                                categories: store.calendarState.categories,
                                dropCoordinator: dropCoordinator,
                                onAction: handle,
                                onCompletion: sendCompletion,
                                selectionRange: interactionCoordinator.previewRange,
                                draggingSourceID: interactionCoordinator.draggingSourceID,
                                draggingPreviewSchedule: interactionCoordinator.previewSchedule,
                                isResizingItem: interactionCoordinator.isResizingItem,
                                onRangeGesture: { gesture in
                                    handleRangeGesture(
                                        gesture,
                                        viewportBounds: viewportBounds,
                                        scrollProxy: scrollProxy
                                    )
                                },
                                onItemGesture: { gesture in
                                    handleItemGesture(
                                        gesture,
                                        viewportBounds: viewportBounds,
                                        scrollProxy: scrollProxy
                                    )
                                },
                                onDeleteItem: { requestDelete($0) },
                                onCopyToToday: { copyItemToToday($0) },
                                onSetPriority: { item, priority in
                                    sendItemAction(
                                        ItemActions.setPriority(priority, on: item),
                                        undoLabel: "已设置优先级"
                                    )
                                }
                            )
                            .id(weekStart)
                            .background {
                                GeometryReader { rowProxy in
                                    Color.clear.preference(
                                        key: WeekRowFramePreferenceKey.self,
                                        value: [.init(
                                            weekStart: weekStart,
                                            minY: rowProxy.frame(in: .named("week-stream-viewport")).minY,
                                            maxY: rowProxy.frame(in: .named("week-stream-viewport")).maxY,
                                            windowRevision: windowRevision
                                        )]
                                    )
                                }
                            }
                        }
                    }
                }
                .background {
                    WeekStreamScrollResolver(coordinator: weekStreamScrollCoordinator)
                        .frame(width: 0, height: 0)
                }
            }
            .coordinateSpace(name: "week-stream-viewport")
            .onAppear {
                if let request = weekStreamCentering.pendingRequest {
                    issueCenteringScroll(request, using: scrollProxy, animated: false)
                }
            }
            .onChange(of: requestedCenterRequest) { _, request in
                guard let request else { return }
                let centeringRequest = weekStreamCentering.begin(
                    weekStart: request.weekStart,
                    windowRevision: request.windowRevision
                )
                issueCenteringScroll(
                    centeringRequest,
                    using: scrollProxy,
                    animated: request.animated
                )
            }
            .onPreferenceChange(WeekRowFramePreferenceKey.self) { frames in
                handleWeekStreamViewport(
                    frames: frames,
                    viewportHeight: viewportHeight,
                    scrollProxy: scrollProxy
                )
            }
            .onPreferenceChange(CalendarDateFramePreferenceKey.self) { frames in
                dateFrameMap = CalendarDateFrameMap(frames: frames)
                if let anchor = quickCreatePresentation?.anchorDate,
                   let frame = dateFrameMap.frame(for: anchor) {
                    lastEditorAnchorFrame = frame
                }
            }
            .onChange(of: autoScrollDriver.latestTick) { _, tick in
                guard let tick else { return }
                advanceRangeAutoScroll(
                    tick,
                    viewportBounds: viewportBounds,
                    scrollProxy: scrollProxy
                )
            }
        }
    }

    private func handleRangeGesture(
        _ gesture: WeekRowRangeGesture,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        switch gesture {
        case let .began(date, target, point):
            cancelRangeAutoScroll()
            interactionCoordinator.pointerDown(on: date, target: target, point: point)
        case let .changed(point):
            let date = dateFrameMap.date(at: point)
            _ = interactionCoordinator.updatePointer(
                point: point,
                over: date,
                viewportBounds: viewportBounds
            )
            autoScrollExecutionDriver.cancel()
            autoScrollDriver.update(direction: interactionCoordinator.autoScrollDirection)
        case let .ended(point):
            cancelRangeAutoScroll()
            let releaseDate = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            let action = interactionCoordinator.pointerUp(at: point, over: releaseDate)
            presentQuickCreate(for: action, clickPoint: point)
        }
    }

    private func handleItemGesture(
        _ gesture: WeekRowItemGesture,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        switch gesture {
        case let .began(date, target, source, point):
            cancelRangeAutoScroll()
            interactionCoordinator.pointerDown(
                on: date,
                target: target,
                source: source,
                point: point
            )
        case let .changed(point):
            let date = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            _ = interactionCoordinator.updatePointer(
                point: point,
                over: date,
                viewportBounds: viewportBounds
            )
            autoScrollExecutionDriver.cancel()
            autoScrollDriver.update(direction: interactionCoordinator.autoScrollDirection)
        case let .ended(point):
            cancelRangeAutoScroll()
            let origin = interactionCoordinator.pressOrigin
            let releaseDate = dateFrameMap.date(at: point) ?? dateFrameMap.nearestDate(to: point)
            guard case let .submitMutation(pending) = interactionCoordinator.pointerUp(
                at: point,
                over: releaseDate
            ) else {
                return
            }
            if commitSameDayUntimedReorder(
                pending,
                from: origin,
                to: point,
                on: releaseDate
            ) {
                return
            }
            if commitMoveToDateUnderPointer(pending, on: releaseDate) {
                return
            }
            commitWeekMutation(pending)
        }
    }

    /// Month chips use the existing item-drag gesture, not system `.draggable`.
    /// Same-column untimed drags shift by how many lanes the pointer moved,
    /// so we do not depend on a drop target or reconstructed cell Y.
    /// Same-day resize is treated as a body drag: a one-day untimed chip
    /// cannot shrink, and narrow month cells often start on a handle.
    private func commitSameDayUntimedReorder(
        _ pending: PendingCalendarMutation,
        from origin: CGPoint?,
        to point: CGPoint,
        on releaseDate: CalendarDate?
    ) -> Bool {
        guard pending.operation == .move,
              case let .item(item) = pending.source,
              UntimedItemReorder.isReorderable(item)
        else { return false }

        let sourceDate = pending.originalSchedule.startDate
        if let origin, let releaseDate, releaseDate != sourceDate {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            if abs(dx) >= abs(dy) {
                return false
            }
        }
        let stayedInCell: Bool
        if let cellFrame = dateFrameMap.frame(for: sourceDate) {
            // Vertical slop only. Crossing a cell's left/right edge is a date move.
            stayedInCell = cellFrame.insetBy(dx: 0, dy: -10).contains(point)
        } else {
            stayedInCell = releaseDate == sourceDate
        }
        guard stayedInCell else { return false }

        let lanePitch = WeekRowMetrics.laneHeight + WeekRowMetrics.laneSpacing
        guard let origin, lanePitch > 0 else { return true }
        let shift = Int(((point.y - origin.y) / lanePitch).rounded())
        let ids = UntimedItemReorder.reorderableIDs(
            on: sourceDate,
            in: store.calendarState,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
        guard let ordered = UntimedItemReorder.moving(item.id, byLanes: shift, in: ids) else {
            return true
        }

        let sourceID = item.id
        Task {
            do {
                _ = try await dropCoordinator.acceptUntimedReorder(
                    .item(sourceID),
                    orderedIDs: ordered,
                    on: sourceDate
                )
            } catch {
                // Same-day path already claimed the drop; do not date-move.
            }
        }
        return true
    }

    /// Relocate by the cell under the pointer, not the live preview schedule.
    /// Preview dates can stay stale when date frames miss a few drag samples.
    private func commitMoveToDateUnderPointer(
        _ pending: PendingCalendarMutation,
        on releaseDate: CalendarDate?
    ) -> Bool {
        guard pending.operation == .move,
              let releaseDate,
              releaseDate != pending.originalSchedule.startDate
        else { return false }
        switch pending.source {
        case let .item(item):
            Task {
                try? await dropCoordinator.accept(.item(item.id), on: releaseDate)
            }
            return true
        case .occurrence:
            return false
        }
    }

    /// Shared commit path for month-row drag and week-grid drag.
    private func commitWeekMutation(_ pending: PendingCalendarMutation) {
        if case .occurrence = pending.source {
            interactionCoordinator.beginPendingRecurrenceScope()
        }
        Task {
            do {
                try await dropCoordinator.accept(pending)
            } catch {
                interactionCoordinator.completePendingMutation()
            }
        }
    }

    private func advanceRangeAutoScroll(
        _ tick: CalendarInteractionAutoScrollTick,
        viewportBounds: CGRect,
        scrollProxy: ScrollViewProxy
    ) {
        guard interactionCoordinator.isDragging,
              interactionCoordinator.autoScrollDirection == tick.direction
        else {
            return
        }
        let pointer = interactionCoordinator.latestPointer ?? CGPoint(
            x: viewportBounds.midX,
            y: tick.direction == .earlier ? viewportBounds.minY : viewportBounds.maxY
        )
        guard let cursorDate = dateFrameMap.date(at: pointer)
            ?? dateFrameMap.nearestDate(to: pointer)
            ?? interactionCoordinator.selectionCursorDate
        else {
            return
        }

        let targetDate = cursorDate.addingDays(tick.direction.dayDelta)
        interactionCoordinator.refreshInteraction(over: targetDate)
        let plan = WeekStreamAutoScrollRouting.plan(
            cursorDate: cursorDate,
            direction: tick.direction,
            loadedWeekStarts: model.weekStarts
        )
        autoScrollExecutionDriver.execute(
            plan: plan,
            visibleWeek: WeekStreamModel.weekStart(containing: cursorDate),
            direction: tick.direction,
            loadedWeekStarts: { model.weekStarts },
            extend: { direction, visibleWeek in
                switch direction {
                case .earlier:
                    _ = model.extendEarlier(visibleWeek: visibleWeek, pixelOffset: 0)
                case .later:
                    _ = model.extendLater(visibleWeek: visibleWeek, pixelOffset: 0)
                }
            },
            scroll: { targetWeek, direction in
                scrollProxy.scrollTo(
                    targetWeek,
                    anchor: direction == .earlier ? .top : .bottom
                )
            }
        )
    }

    private func openQuickCreate(
        on date: CalendarDate,
        endDate: CalendarDate? = nil,
        startTime: MinuteOfDay? = nil,
        endTime: MinuteOfDay? = nil,
        anchorFrame: CGRect? = nil
    ) {
        presentQuickCreate(
            QuickCreatePresentation.forDay(
                date,
                startTime: startTime,
                endTime: endTime,
                endDate: endDate
            ),
            anchorFrame: anchorFrame
        )
    }

    private func presentQuickCreate(
        for action: CalendarInteractionAction?,
        clickPoint: CGPoint? = nil
    ) {
        guard let presentation = MonthQuickCreateRouting.presentation(for: action)
        else {
            return
        }
        // Prefer the actual click (root coords) over dateFrameMap — map frames can sit
        // outside the visible window after scroll and pin the card to the top edge.
        let clickAnchor = clickPoint.map {
            CGRect(x: $0.x - 16, y: $0.y - 12, width: 32, height: 24)
        }
        presentQuickCreate(presentation, anchorFrame: clickAnchor)
    }

    private func presentQuickCreate(
        _ presentation: QuickCreatePresentation,
        anchorFrame: CGRect? = nil
    ) {
        cancelRangeAutoScroll()
        selectedDayDrawerDate = nil
        editorSession = nil
        quickCreateSessionID = UUID()
        lastEditorAnchorFrame = resolvedCreateAnchorFrame(
            preferred: anchorFrame,
            date: presentation.anchorDate
        )
        // Keep last measured size as a better first guess than 0×0.
        if quickCreateMeasuredContentSize.height < 1 {
            quickCreateMeasuredContentSize = CGSize(
                width: QuickCreatePopover.preferredWidth,
                height: QuickCreateOverlayPresentation.estimatedCardHeight
            )
        }
        withAnimation(motionPolicy.overlayAnimation) {
            quickCreatePresentation = presentation
        }
        interactionCoordinator.openEditor(for: presentation.range, anchor: presentation.anchorDate)
    }

    /// Only accept anchors that sit on-screen; otherwise fall back to window center.
    private func resolvedCreateAnchorFrame(
        preferred: CGRect?,
        date: CalendarDate
    ) -> CGRect {
        let mapped = preferred ?? dateFrameMap.frame(for: date) ?? lastEditorAnchorFrame
        // Without window bounds here, reject absurd frames (e.g. y ≪ 0 from scroll content).
        if let mapped,
           mapped.width.isFinite, mapped.height.isFinite,
           mapped.origin.x.isFinite, mapped.origin.y.isFinite,
           mapped.minY > -400, mapped.maxY < 4000,
           mapped.width >= 0, mapped.height >= 0 {
            return mapped
        }
        return CGRect(x: 400, y: 280, width: 40, height: 40)
    }

    private func dismissQuickCreate() {
        cancelRangeAutoScroll()
        withAnimation(motionPolicy.overlayAnimation) {
            quickCreatePresentation = nil
        }
        lastEditorAnchorFrame = nil
        quickCreateMeasuredContentSize = .zero
        // Always release the create lock so the next empty-cell click can start.
        interactionCoordinator.cancel()
    }

    /// Full-window tap catcher behind editor cards. The card sits above and absorbs its own hits.
    @ViewBuilder
    private func dismissScrim(action: @escaping () -> Void) -> some View {
        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(motionPolicy.overlayAnimation) {
                    action()
                }
            }
            .accessibilityLabel("关闭编辑")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("editor-dismiss-scrim")
    }

    private func issueCenteringScroll(
        _ request: WeekStreamCenteringRequest,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        Task { @MainActor in
            await Task.yield()
            let usesAnimatedScroll = animated && motionPolicy.snapAnimation != nil
            guard weekStreamCentering.markScrollIssued(
                for: request,
                animated: usesAnimatedScroll
            ) else {
                return
            }
            align(
                proxy,
                to: request.weekStart,
                anchor: .center,
                animated: usesAnimatedScroll
            )
            if usesAnimatedScroll, let delay = motionPolicy.centeringSettleDelay {
                try? await Task.sleep(for: delay)
                guard weekStreamCentering.markAnimationSettled(for: request) else { return }
            }
            await Task.yield()
            confirmDeferredCentering(for: request, using: proxy)
        }
    }

    private func confirmDeferredCentering(
        for request: WeekStreamCenteringRequest,
        using proxy: ScrollViewProxy
    ) {
        guard weekStreamCentering.pendingRequest == request else {
            return
        }
        switch weekStreamCentering.confirmDeferredCentering(for: request) {
        case .wait, .ready:
            return
        case let .retry(request):
            issueCenteringScroll(request, using: proxy, animated: false)
        }
    }

    private func align(
        _ proxy: ScrollViewProxy,
        to weekStart: CalendarDate,
        anchor: UnitPoint,
        animated: Bool = true
    ) {
        guard motionPolicy.shouldAlignToWeek else { return }
        guard animated, let animation = motionPolicy.snapAnimation else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(weekStart, anchor: anchor)
            }
            return
        }
        withAnimation(animation) {
            proxy.scrollTo(weekStart, anchor: anchor)
        }
    }

    private func cancelRangeAutoScroll() {
        autoScrollDriver.cancel()
        autoScrollExecutionDriver.cancel()
    }

    private func resolvedEditorAnchorFrame(for date: CalendarDate, windowBounds: CGRect) -> CGRect {
        let visible = windowBounds.insetBy(dx: 8, dy: 8)
        // 1) Explicit click / week-cell anchor captured at open
        if let last = lastEditorAnchorFrame, last.intersects(visible) {
            return last
        }
        // 2) Date cell frame only if currently on-screen
        if let frame = dateFrameMap.frame(for: date), frame.intersects(visible) {
            return frame
        }
        // 3) Never use off-screen map frames (they pin the card to the top/bottom edge).
        return CGRect(
            x: windowBounds.midX - 20,
            y: windowBounds.midY - 20,
            width: 40,
            height: 40
        )
    }

    private var isExtendingWeekStream: Bool {
        weekStreamRestoration.isLocked
    }

    private func handleWeekStreamViewport(
        frames: [WeekRowViewportFrame],
        viewportHeight: CGFloat,
        scrollProxy: ScrollViewProxy
    ) {
        // Destroying the month ScrollView can emit a last preference pass of the
        // leading-edge weeks. Ignore it so week mode cannot rewrite month focus.
        guard primaryViewMode == .month else { return }

        switch weekStreamCentering.receiveViewport(
            frames: frames,
            viewportHeight: viewportHeight
        ) {
        case .wait:
            return
        case let .retry(request):
            issueCenteringScroll(request, using: scrollProxy, animated: false)
            return
        case .ready:
            break
        }

        if isExtendingWeekStream {
            switch weekStreamRestoration.receive(frames: frames) {
            case .wait, .confirmed:
                return
            case let .adjustContentOffset(correction):
                weekStreamScrollCoordinator.adjustViewport(correction)
                return
            }
        }

        let windowRevision = WeekStreamWindowRevision(weekStarts: model.weekStarts)
        let currentFrames = frames.filter { $0.windowRevision == windowRevision }
        if let focusWeek = WeekStreamViewport.focusWeek(
            in: currentFrames,
            viewportHeight: viewportHeight
        ),
           focusWeek != model.focusWeek {
            model.updateFocus(toWeekStarting: focusWeek)
        }

        guard let request = WeekStreamViewport.extensionRequest(
                in: currentFrames,
                loadedWeekStarts: model.weekStarts,
                viewportHeight: viewportHeight
              ),
              weekStreamRestoration.begin(request: request)
        else {
            return
        }

        let anchor: WeekStreamAnchor
        switch request.direction {
        case .earlier:
            anchor = model.extendEarlier(
                visibleWeek: request.anchor.weekStart,
                pixelOffset: request.anchor.pixelOffset
            )
        case .later:
            anchor = model.extendLater(
                visibleWeek: request.anchor.weekStart,
                pixelOffset: request.anchor.pixelOffset
            )
        }
        weekStreamRestoration.expect(
            anchor: anchor,
            windowRevision: WeekStreamWindowRevision(weekStarts: model.weekStarts)
        )
    }
}
