import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct ItemDetailPopover: View {
    let item: ProjectedItem
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    let onClose: () -> Void
    var onOpenNote: (NoteID) -> Void = { _ in }
    @State private var pendingAction: DetailAction?
    @State private var editorConfiguration: ItemEditorConfiguration?
    @State private var deleteConfirmationShown = false
    @State private var localError: String?
    @State private var recoveryAction: WorkspaceRecoveryAction?
    @State private var noteRelationModel: CalendarNoteIntegrationModel?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        Group {
            if let editorConfiguration {
                ItemEditForm(
                    configuration: editorConfiguration,
                    store: store,
                    categories: categories,
                    onOpenNote: onOpenNote,
                    onCancel: { self.editorConfiguration = nil },
                    onSaved: onClose,
                    onCopyToToday: { _ in copyToToday() }
                )
            } else {
                detailContent
            }
        }
        .frame(width: ItemEditForm.preferredWidth)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .confirmationDialog("选择应用范围", isPresented: scopeConfirmationBinding, titleVisibility: .visible) {
            Button("仅本次") { apply(scope: .onlyThis) }
            Button("本次及以后") { apply(scope: .thisAndFuture) }
            Button("取消", role: .cancel) { pendingAction = nil }
        }
        .confirmationDialog("删除此事项？", isPresented: $deleteConfirmationShown, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteOneOff() }
            Button("取消", role: .cancel) {}
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.title)
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Text(item.schedule.startTime == nil ? "全天事项" : "定时事项")
                .foregroundStyle(theme.secondaryText)
            Text("\(Self.dateString(item.schedule.startDate)) 至 \(Self.dateString(item.schedule.endDate))")
                .foregroundStyle(theme.secondaryText)
            if let startTime = item.schedule.startTime,
               let endTime = item.schedule.endTime {
                Text("\(Self.timeString(startTime))–\(Self.timeString(endTime))")
                    .foregroundStyle(theme.secondaryText)
            } else {
                Text("全天")
                    .foregroundStyle(theme.secondaryText)
            }
            if !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("随记")
                        .font(EditorFormStyle.label)
                        .foregroundStyle(theme.secondaryText)
                    MarkdownNotesPreview(markdown: item.notes)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.subtleBorder.opacity(0.16))
                )
            }
            if let noteRelationModel {
                Divider()
                CalendarNoteRelationPopover(
                    model: noteRelationModel,
                    store: store,
                    onOpenNote: onOpenNote
                )
            }
            if let message = localError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.footnote).foregroundStyle(theme.error)
                    if recoveryAction != nil {
                        Button("继续恢复", action: retryRecovery)
                            .controlSize(.small)
                    }
                }
            }
            Divider()
            HStack {
                Button("编辑") { begin(.edit) }
                    .disabled(store.phase != .ready)
                Button("复制到当天") { copyToToday() }
                    .disabled(store.phase != .ready)
                Button("删除", role: .destructive) { begin(.delete) }
                    .disabled(store.phase != .ready)
                Spacer()
            }
        }
        .onAppear {
            if noteRelationModel == nil {
                noteRelationModel = CalendarNoteIntegrationModel(
                    target: calendarTarget(for: item),
                    store: store
                )
            } else {
                noteRelationModel?.refresh()
            }
        }
        .padding(18)
    }

    private var scopeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil && isRecurring },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var isRecurring: Bool {
        if case .occurrence = item { true } else { false }
    }

    private func begin(_ action: DetailAction) {
        localError = nil
        recoveryAction = nil
        guard isRecurring else {
            if action == .edit {
                editorConfiguration = .oneOff(item: oneOffItem)
            } else {
                deleteConfirmationShown = true
            }
            return
        }
        pendingAction = action
    }

    private func apply(scope: SeriesScope) {
        guard let action = pendingAction,
              case let .occurrence(occurrence) = item,
              let series = store.calendarState.recurrence.series[occurrence.key.seriesID]
        else {
            localError = "找不到重复事项"
            pendingAction = nil
            return
        }
        pendingAction = nil
        switch action {
        case .edit:
            editorConfiguration = .occurrence(
                series: series,
                occurrence: occurrence,
                scope: scope
            )
        case .delete:
            let mode = ItemEditorMode.editOccurrence(series: series, key: occurrence.key, scope: scope)
            let draft = ItemDraft(occurrence: occurrence, series: series)
            let vm = ItemEditorViewModel(mode: mode, draft: draft)
            do {
                let command = try vm.makeDeleteCommand(newSeriesID: UUID())
                sendDelete(command)
            } catch {
                localError = vm.validationMessage ?? "无法删除事项"
            }
        }
    }

    private func copyToToday() {
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        let today = CalendarDate.localDay(containing: Date(), in: .current)
        Task {
            do {
                apply(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(
                        try ItemActions.copyToDay(item, day: today, now: Date()),
                        undoLabel: "已复制到当天"
                    )
                ))
            } catch {
                localError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func deleteOneOff() {
        let vm = ItemEditorViewModel(mode: .editItem(oneOffItem), draft: ItemDraft(item: oneOffItem))
        do {
            sendDelete(try vm.makeDeleteCommand(newSeriesID: UUID()))
        } catch {
            localError = vm.validationMessage ?? "无法删除事项"
        }
    }

    private func sendDelete(_ command: CalendarCommand) {
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        Task {
            do {
                apply(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: "已删除事项")
                ))
            } catch {
                localError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func apply(_ presentation: WorkspaceMutationPresentation) {
        localError = presentation.message
        recoveryAction = presentation.recoveryAction
        if presentation.allowsDismissal {
            onClose()
        }
    }

    private func retryRecovery() {
        guard let recoveryAction else { return }
        Task { @MainActor in
            apply(await WorkspaceMutationOutcomePresenter.retry(recoveryAction, in: store))
        }
    }

    private var oneOffItem: CalendarItem {
        guard case let .item(item) = item else {
            preconditionFailure("A recurring item cannot use a one-off action.")
        }
        return item
    }

    private static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }

    private static func dateString(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    private func calendarTarget(for item: ProjectedItem) -> CalendarTargetID {
        switch item {
        case let .item(calendarItem):
            .item(calendarItem.id)
        case let .occurrence(occurrence):
            .occurrence(occurrence.key)
        }
    }
}

private enum DetailAction {
    case edit
    case delete
}

enum ItemEditorConfiguration: Identifiable {
    case oneOff(item: CalendarItem)
    case occurrence(series: WeeklySeries, occurrence: CalendarOccurrence, scope: SeriesScope)

    var id: String {
        switch self {
        case let .oneOff(item): "item-\(item.id.uuidString)"
        case let .occurrence(_, occurrence, scope): "occurrence-\(occurrence.id.seriesID.uuidString)-\(scope)"
        }
    }

    var mode: ItemEditorMode {
        switch self {
        case let .oneOff(item): .editItem(item)
        case let .occurrence(series, occurrence, scope):
            .editOccurrence(series: series, key: occurrence.key, scope: scope)
        }
    }

    var draft: ItemDraft {
        switch self {
        case let .oneOff(item): ItemDraft(item: item)
        case let .occurrence(series, occurrence, _): ItemDraft(occurrence: occurrence, series: series)
        }
    }

    var canEditRule: Bool {
        if case let .occurrence(_, _, scope) = self {
            return scope == .thisAndFuture
        }
        return false
    }

    var calendarTarget: CalendarTargetID {
        switch self {
        case let .oneOff(item):
            .item(item.id)
        case let .occurrence(series, occurrence, scope):
            scope == .thisAndFuture ? .series(series.id) : .occurrence(occurrence.key)
        }
    }

    var projectedItem: ProjectedItem {
        switch self {
        case let .oneOff(item):
            .item(item)
        case let .occurrence(_, occurrence, _):
            .occurrence(occurrence)
        }
    }
}

enum ItemEditorMoreDetailsPolicy {
    static func isInitiallyExpanded(
        draft: ItemDraft,
        canEditRule: Bool,
        hasNoteRelations: Bool
    ) -> Bool {
        !draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || canEditRule
            || hasNoteRelations
            || draft.repeatsWeekly
    }
}

struct ItemEditForm: View {
    /// Compact editor card — calendar-tool density, not form-wizard spacing.
    nonisolated static let preferredWidth: CGFloat = 360

    let configuration: ItemEditorConfiguration
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    let onOpenNote: (NoteID) -> Void
    let onCancel: () -> Void
    let onSaved: () -> Void
    var onCopyToToday: ((ProjectedItem) -> Void)? = nil
    var onManageCategories: ((UUID?) -> Void)? = nil
    @FocusState private var titleFocused: Bool
    @StateObject private var model: ItemEditorViewModel
    @State private var categoryOption: String
    @State private var localError: String?
    @State private var recoveryAction: WorkspaceRecoveryAction?
    @State private var deleteConfirmationShown = false
    @State private var showMoreDetails: Bool
    @State private var noteRelationModel: CalendarNoteIntegrationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openCategoryManager) private var openCategoryManager

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    init(
        configuration: ItemEditorConfiguration,
        store: WorkspaceStore,
        categories: [CalendarCategory],
        onOpenNote: @escaping (NoteID) -> Void = { _ in },
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onCopyToToday: ((ProjectedItem) -> Void)? = nil,
        onManageCategories: ((UUID?) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.store = store
        self.categories = categories
        self.onOpenNote = onOpenNote
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onCopyToToday = onCopyToToday
        self.onManageCategories = onManageCategories
        let draft = configuration.draft
        let noteRelationModel = CalendarNoteIntegrationModel(
            target: configuration.calendarTarget,
            store: store
        )
        _model = StateObject(wrappedValue: ItemEditorViewModel(
            mode: configuration.mode,
            draft: draft
        ))
        _categoryOption = State(initialValue: draft.categoryID.uuidString)
        _noteRelationModel = State(initialValue: noteRelationModel)
        _showMoreDetails = State(initialValue: ItemEditorMoreDetailsPolicy.isInitiallyExpanded(
            draft: draft,
            canEditRule: configuration.canEditRule,
            hasNoteRelations: noteRelationModel.primaryNote != nil
                || !noteRelationModel.referenceNotes.isEmpty
        ))
    }

    var body: some View {
        // No ScrollView: it was expanding to maxHeight and leaving huge empty bands.
        VStack(spacing: 0) {
            header
            thinRule
            VStack(alignment: .leading, spacing: EditorFormStyle.contentSpacing) {
                titleField
                categoryBlock
                scheduleBlock
                EditorMoreDetailsDisclosure(isExpanded: $showMoreDetails) {
                    VStack(alignment: .leading, spacing: EditorFormStyle.contentSpacing) {
                        if configuration.canEditRule {
                            recurrenceBlock
                        }
                        MarkdownNotesEditor(text: $model.draft.notes)
                        CalendarNoteRelationPopover(
                            model: noteRelationModel,
                            store: store,
                            onOpenNote: onOpenNote
                        )
                    }
                }
                if let message = localError ?? model.validationMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(EditorFormStyle.caption)
                            .foregroundStyle(theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                        if recoveryAction != nil {
                            Button("继续恢复", action: retryRecovery)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            thinRule
            footer
        }
        .frame(width: Self.preferredWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .onAppear {
            noteRelationModel.refresh()
            titleFocused = true
        }
        .onChange(of: model.draft.categoryID) { _, id in
            categoryOption = id.uuidString
        }
        // Return inserts a newline in 随记; save via ⌘↩ or the button.
        .onKeyPress(.return) {
            guard titleFocused else { return .ignored }
            save()
            return .handled
        }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .confirmationDialog("删除此事项？", isPresented: $deleteConfirmationShown, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: deleteItem)
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Text("编辑事项")
                .font(EditorFormStyle.title)
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(theme.subtleBorder.opacity(0.35), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("删除事项", role: .destructive) {
                    deleteConfirmationShown = true
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.phase != .ready)
            if let onCopyToToday {
                Button("复制到当天") {
                    onCopyToToday(configuration.projectedItem)
                }
                .controlSize(.small)
                .disabled(store.phase != .ready)
                .help("复制一份到今天，然后可以拖到其他日期")
            }
            Spacer(minLength: 0)
            Button("取消", action: onCancel)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
            Button("保存", action: save)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.phase != .ready)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var thinRule: some View {
        Rectangle()
            .fill(theme.separator.opacity(0.55))
            .frame(height: 1)
    }

    // MARK: - Content

    private var titleField: some View {
        TextField("标题", text: $model.draft.title)
            .textFieldStyle(.roundedBorder)
            .font(EditorFormStyle.body)
            .focused($titleFocused)
    }

    private var categoryBlock: some View {
        HStack(spacing: EditorFormStyle.categoryLabelSpacing) {
            Text("分类")
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
            EditorCategoryPicker(
                categories: categories,
                selectedID: model.draft.categoryID,
                footerTitle: "新建分类…",
                onSelect: selectCategory,
                onFooter: {
                    if let onManageCategories {
                        onManageCategories(model.draft.categoryID)
                    } else {
                        openCategoryManager.callAsFunction(categoryID: model.draft.categoryID)
                    }
                }
            )
            Spacer(minLength: 0)
        }
        .frame(minHeight: EditorFormStyle.fieldMinHeight)
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private func selectCategory(_ id: UUID) {
        categoryOption = id.uuidString
        model.draft.categoryID = id
    }

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            // 全天 / 定时 — short chips, no long checkbox copy
            HStack(spacing: 0) {
                timeModeChip(title: "全天", selected: !model.draft.usesTime) {
                    if model.draft.usesTime {
                        model.draft.usesTime = false
                    }
                }
                timeModeChip(title: "定时", selected: model.draft.usesTime) {
                    if !model.draft.usesTime {
                        model.draft.usesTime = true
                        model.usesTimeDidChange()
                    }
                }
            }
            .padding(2)
            .background(
                theme.subtleBorder.opacity(0.22),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )

            fieldRow("开始") {
                EditorDateChip(date: startDateBinding)
                if model.draft.usesTime {
                    EditorTimeChip(date: startTimeBinding)
                        .help("开始时间")
                }
                Spacer(minLength: 0)
            }

            fieldRow("结束") {
                EditorDateChip(date: endDateBinding)
                if model.draft.usesTime {
                    EditorTimeChip(date: endTimeBinding)
                        .help("结束时间；跨日可到次日 00:00")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private func timeModeChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
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
    }

    private var recurrenceBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            Text("重复")
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
            EditorRecurrenceModePicker(mode: recurrenceModeBinding, allowsClearing: false)
            if model.draft.recurrenceMode == .weekly {
                EditorWeekdayPicker(weekdays: $model.draft.weekdays)
            }
            Toggle(isOn: recurrenceEndEnabledBinding) {
                Text("设置结束日期")
                    .font(EditorFormStyle.control)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if model.draft.recurrenceEndDate != nil {
                fieldRow("直到") {
                    EditorDateChip(date: recurrenceEndBinding)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(EditorFormStyle.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private var fieldBlockBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.subtleBorder.opacity(0.16))
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
                .frame(width: EditorFormStyle.labelWidth, alignment: .leading)
            content()
        }
        .frame(minHeight: EditorFormStyle.fieldMinHeight)
    }

    // MARK: - Bindings & actions

    private var recurrenceModeBinding: Binding<ItemRecurrenceMode> {
        Binding(
            get: { model.draft.recurrenceMode },
            set: { model.draft.recurrenceMode = $0 }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.startDate.editorDate },
            set: { model.draft.startDate = .editorDate(containing: $0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.endDate.editorDate },
            set: { model.draft.endDate = .editorDate(containing: $0) }
        )
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { model.draft.startTime.editorDate },
            set: { newValue in
                model.draft.startTime = .editorMinute(containing: newValue)
                model.startTimeDidChange()
            }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { model.draft.endTime.editorDate },
            set: { model.draft.endTime = .editorMinute(containing: $0) }
        )
    }

    private var recurrenceEndEnabledBinding: Binding<Bool> {
        Binding(get: { model.draft.recurrenceEndDate != nil }, set: {
            model.draft.recurrenceEndDate = $0 ? model.draft.startDate : nil
        })
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (model.draft.recurrenceEndDate ?? model.draft.startDate).editorDate },
            set: { model.draft.recurrenceEndDate = .editorDate(containing: $0) }
        )
    }

    private func deleteItem() {
        localError = nil
        recoveryAction = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        let command: CalendarCommand
        do {
            command = try model.makeDeleteCommand(newSeriesID: UUID())
        } catch {
            localError = model.validationMessage ?? "无法删除事项"
            return
        }
        Task {
            do {
                apply(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: "已删除事项")
                ))
            } catch {
                localError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func save() {
        localError = nil
        recoveryAction = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        // Pin is retired as a product feature; always clear on save.
        model.draft.isPinned = false
        let command: CalendarCommand
        do {
            command = try model.makeCommand(
                now: Date(),
                newItemID: UUID(),
                newSeriesID: UUID(),
                timeZoneIdentifier: TimeZone.current.identifier
            )
        } catch {
            localError = model.validationMessage ?? "无法保存事项"
            return
        }
        Task {
            do {
                apply(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: "已更新事项")
                ))
            } catch {
                localError = WorkspaceMutationOutcomePresenter.message(for: error)
            }
        }
    }

    private func apply(_ presentation: WorkspaceMutationPresentation) {
        localError = presentation.message
        recoveryAction = presentation.recoveryAction
        if presentation.allowsDismissal {
            onSaved()
        }
    }

    private func retryRecovery() {
        guard let recoveryAction else { return }
        Task { @MainActor in
            apply(await WorkspaceMutationOutcomePresenter.retry(recoveryAction, in: store))
        }
    }
}
