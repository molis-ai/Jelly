import CalendarDomain
import SwiftUI

struct DayDrawerView: View {
    let date: CalendarDate
    let store: WorkspaceStore
    let categories: [UUID: CalendarCategory]
    let hiddenCategoryIDs: Set<UUID>
    let onClose: () -> Void
    let onQuickCreate: (CalendarDate) -> Void
    let onOpenDetail: (ProjectedItem) -> Void
    var onDelete: ((ProjectedItem) -> Void)?
    var onCopyToToday: ((ProjectedItem) -> Void)?
    var dropCoordinator: CalendarDropCoordinator?
    @StateObject private var model: DayDrawerViewModel
    @State private var actionError: String?
    @State private var recoveryAction: WorkspaceRecoveryAction?
    /// Arrow-key selection into `model.items`; nil until the first arrow press,
    /// so mouse-only users never see a selection ring they did not ask for.
    @State private var keyboardSelectionIndex: Int?
    @FocusState private var drawerHasFocus: Bool

    init(
        date: CalendarDate,
        store: WorkspaceStore,
        categories: [UUID: CalendarCategory],
        hiddenCategoryIDs: Set<UUID>,
        onClose: @escaping () -> Void,
        onQuickCreate: @escaping (CalendarDate) -> Void,
        onOpenDetail: @escaping (ProjectedItem) -> Void,
        onDelete: ((ProjectedItem) -> Void)? = nil,
        onCopyToToday: ((ProjectedItem) -> Void)? = nil,
        dropCoordinator: CalendarDropCoordinator? = nil
    ) {
        self.date = date
        self.store = store
        self.categories = categories
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.onClose = onClose
        self.onQuickCreate = onQuickCreate
        self.onOpenDetail = onOpenDetail
        self.onDelete = onDelete
        self.onCopyToToday = onCopyToToday
        self.dropCoordinator = dropCoordinator
        _model = StateObject(wrappedValue: DayDrawerViewModel(
            date: date,
            state: store.calendarState,
            hiddenCategoryIDs: hiddenCategoryIDs
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.date.month)月\(model.date.day)日")
                            .font(.headline)
                        Text("\(model.items.count) 件 · 已完成 \(completedCount) 件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }

                if model.items.isEmpty {
                    ContentUnavailableView("当天没有事项", systemImage: "calendar")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                CalendarItemRow(
                                    item: item,
                                    category: categories[item.categoryID],
                                    onCompletion: sendCompletion,
                                    onOpenDetail: onOpenDetail,
                                    onDelete: { onDelete?(item) },
                                    onCopyToToday: onCopyToToday.map { action in
                                        { action(item) }
                                    },
                                    onSetPriority: { setPriority($0, on: item) },
                                    allowsSwipeToDelete: CalendarItemRowPlacement.dayDrawer.allowsSwipeToDelete,
                                    isKeyboardSelected: keyboardSelectionIndex == index,
                                    onDropTransfer: untimedDropHandler(for: item)
                                )
                                .id(item.id)
                            }
                        }
                    }
                }

                Button("新建事项") {
                    onQuickCreate(model.quickCreateDate)
                }

                if let actionError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(actionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        if recoveryAction != nil {
                            Button("继续恢复", action: retryRecovery)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
            .overlay(alignment: .leading) {
                Rectangle().fill(.separator).frame(width: 1)
            }
            .focusable(true)
            .focused($drawerHasFocus)
            .onAppear {
                // Claim keyboard focus so Esc / N / arrows reach the drawer
                // without a preliminary click into it.
                drawerHasFocus = true
            }
            .onChange(of: store.calendarState) { _, state in
                model.refresh(state: state, hiddenCategoryIDs: hiddenCategoryIDs)
            }
            .onChange(of: date) { _, date in
                keyboardSelectionIndex = nil
                model.retarget(date: date, state: store.calendarState, hiddenCategoryIDs: hiddenCategoryIDs)
            }
            .onChange(of: hiddenCategoryIDs) { _, hidden in
                model.refresh(state: store.calendarState, hiddenCategoryIDs: hidden)
            }
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
            .onKeyPress("n") {
                onQuickCreate(model.quickCreateDate)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveKeyboardSelection(-1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveKeyboardSelection(1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.return) {
                openKeyboardSelection()
                return .handled
            }
        }
    }

    private func moveKeyboardSelection(_ delta: Int, proxy: ScrollViewProxy) {
        let count = model.items.count
        guard count > 0 else { return }
        let next: Int
        if let current = keyboardSelectionIndex {
            next = min(max(current + delta, 0), count - 1)
        } else {
            next = delta > 0 ? 0 : count - 1
        }
        keyboardSelectionIndex = next
        drawerHasFocus = true
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(model.items[next].id, anchor: .center)
        }
    }

    private func openKeyboardSelection() {
        guard let index = keyboardSelectionIndex,
              model.items.indices.contains(index)
        else { return }
        onOpenDetail(model.items[index])
    }

    private func untimedDropHandler(for item: ProjectedItem) -> ((CalendarTransferPayload) -> Bool)? {
        guard case let .item(target) = item,
              UntimedItemReorder.isReorderable(target),
              let dropCoordinator
        else { return nil }
        let date = model.date
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

    private var completedCount: Int {
        model.items.filter { $0.completedAt != nil }.count
    }

    private func setPriority(_ priority: ItemPriority, on item: ProjectedItem) {
        actionError = nil
        recoveryAction = nil
        guard store.phase == .ready else {
            actionError = "日历尚未准备好，优先级没有保存。"
            return
        }
        Task {
            do {
                receive(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(
                        ItemActions.setPriority(priority, on: item),
                        undoLabel: "已设置优先级"
                    )
                ))
            } catch {
                actionError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func sendCompletion(_ command: CalendarCommand) {
        actionError = nil
        recoveryAction = nil
        guard store.phase == .ready else {
            actionError = "日历尚未准备好，完成状态没有保存。"
            return
        }
        Task {
            do {
                receive(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: "已更新完成状态")
                ))
            } catch {
                actionError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func receive(_ presentation: WorkspaceMutationPresentation) {
        actionError = presentation.message
        recoveryAction = presentation.recoveryAction
    }

    private func retryRecovery() {
        guard let recoveryAction else { return }
        Task { @MainActor in
            receive(await WorkspaceMutationOutcomePresenter.retry(recoveryAction, in: store))
        }
    }
}
