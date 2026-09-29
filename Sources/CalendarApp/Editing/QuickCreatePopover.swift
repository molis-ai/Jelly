import CalendarDomain
import SwiftUI

struct QuickCreatePresentation: Equatable {
    let range: CalendarDateRange
    let anchorDate: CalendarDate
    /// When set (e.g. week-grid hour tap), create form opens with 具体时间 enabled.
    let startTime: MinuteOfDay?
    let endTime: MinuteOfDay?

    init(
        range: CalendarDateRange,
        anchorDate: CalendarDate,
        startTime: MinuteOfDay? = nil,
        endTime: MinuteOfDay? = nil
    ) {
        self.range = range
        self.anchorDate = anchorDate
        self.startTime = startTime
        self.endTime = endTime
    }

    init?(action: CalendarInteractionAction) {
        guard case let .openCreate(range, anchor) = action else { return nil }
        self.init(range: range, anchorDate: anchor)
    }

    /// Seed a single-day create; optional hour slot fills 具体时间 (default 1h block).
    /// Pass `endTime` (and optional `endDate`) when the user dragged a multi-slot band.
    static func forDay(
        _ date: CalendarDate,
        startTime: MinuteOfDay? = nil,
        endTime: MinuteOfDay? = nil,
        endDate: CalendarDate? = nil
    ) -> QuickCreatePresentation {
        guard let start = startTime else {
            return QuickCreatePresentation(
                range: CalendarDateRange(start: date, end: date),
                anchorDate: date
            )
        }
        if let endTime {
            return QuickCreatePresentation(
                range: CalendarDateRange(start: date, end: endDate ?? date),
                anchorDate: date,
                startTime: start,
                endTime: endTime
            )
        }
        let next = start.value + 60
        let resolvedEndDate: CalendarDate
        let end: MinuteOfDay
        if next < 24 * 60 {
            resolvedEndDate = date
            end = MinuteOfDay(hour: next / 60, minute: next % 60)!
        } else {
            // 23:00 → overnight to next day 00:00
            resolvedEndDate = date.addingDays(1)
            end = MinuteOfDay(hour: 0, minute: 0)!
        }
        return QuickCreatePresentation(
            range: CalendarDateRange(start: date, end: resolvedEndDate),
            anchorDate: date,
            startTime: start,
            endTime: end
        )
    }

    static func forTimedSelection(_ intent: WeekGridCreateSelection.Intent) -> QuickCreatePresentation {
        forDay(
            intent.day,
            startTime: intent.startTime,
            endTime: intent.endTime,
            endDate: intent.endDate
        )
    }

    func initialDraft(categoryID: UUID) -> ItemDraft {
        .newItem(
            from: range.start,
            through: range.end,
            categoryID: categoryID,
            startTime: startTime,
            endTime: endTime
        )
    }
}

struct QuickCreateCardSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

enum QuickCreateContentLayout: Equatable {
    case natural
    case scrollable(maximumHeight: CGFloat)

    var maximumHeight: CGFloat? {
        switch self {
        case .natural: nil
        case let .scrollable(maximumHeight): maximumHeight
        }
    }
}

struct QuickCreateOverlayPresentation: Equatable {
    /// Used before preference measures real content — avoids height-0 midY placement
    /// that jumps the card to the window top once the form expands.
    nonisolated static let estimatedCardHeight: CGFloat = 420

    let presentation: QuickCreatePresentation
    let placement: AnchoredEditorPlacement

    init(
        presentation: QuickCreatePresentation,
        measuredContentSize: CGSize,
        anchorFrame: CGRect,
        windowBounds: CGRect
    ) {
        self.presentation = presentation
        let width = measuredContentSize.width > 1
            ? measuredContentSize.width
            : QuickCreatePopover.preferredWidth
        let height = measuredContentSize.height > 1
            ? measuredContentSize.height
            : Self.estimatedCardHeight
        let preferredSize = CGSize(width: width, height: height)
        placement = AnchoredEditorLayout.place(
            cardSize: preferredSize,
            anchorFrame: anchorFrame,
            windowBounds: windowBounds
        )
    }

    var contentLayout: QuickCreateContentLayout {
        placement.requiresInternalScroll
            ? .scrollable(maximumHeight: placement.frame.height)
            : .natural
    }

    var maximumContentHeight: CGFloat? {
        contentLayout.maximumHeight
    }
}

struct QuickCreatePopover: View {
    nonisolated static let preferredWidth: CGFloat = 380

    let store: WorkspaceStore
    let categories: [CalendarCategory]
    let onClose: () -> Void
    var onManageCategories: ((UUID?) -> Void)? = nil
    private let availableWidth: CGFloat
    private let maximumContentHeight: CGFloat?
    @Environment(\.openCategoryManager) private var openCategoryManager
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var titleFocused: Bool
    @StateObject private var model: ItemEditorViewModel
    @State private var categoryOption: String
    @State private var localError: String?
    @State private var recoveryAction: WorkspaceRecoveryAction?
    @State private var showMoreDetails = false
    /// The user tapped “按原样” on the recognized date/time hint.
    @State private var ignoresParsedSchedule = false

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    init(
        presentation: QuickCreatePresentation,
        categories: [CalendarCategory],
        store: WorkspaceStore,
        availableWidth: CGFloat = QuickCreatePopover.preferredWidth,
        maximumContentHeight: CGFloat? = nil,
        onClose: @escaping () -> Void,
        onManageCategories: ((UUID?) -> Void)? = nil
    ) {
        self.store = store
        self.categories = categories
        self.onClose = onClose
        self.onManageCategories = onManageCategories
        self.availableWidth = availableWidth
        self.maximumContentHeight = maximumContentHeight
        let categoryID = categories.first?.id ?? store.calendarState.uncategorizedID
        let draft = presentation.initialDraft(categoryID: categoryID)
        _model = StateObject(wrappedValue: ItemEditorViewModel(mode: .create, draft: draft))
        _categoryOption = State(initialValue: categoryID.uuidString)
        _localError = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let maximumContentHeight {
                ScrollView(.vertical) {
                    measuredEditorContent
                }
                .frame(height: maximumContentHeight)
            } else {
                measuredEditorContent
            }
        }
            .frame(width: availableWidth)
            .background(theme.elevatedSurface)
            .foregroundStyle(theme.primaryText)
            .tint(theme.controlAccent)
            .onAppear { titleFocused = true }
            // Return inserts a newline in 随记; save via ⌘↩ or the button.
            .onKeyPress(.return) {
                guard titleFocused else { return .ignored }
                save()
                return .handled
            }
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
    }

    private var measuredEditorContent: some View {
        editorContent
            .padding(18)
            .frame(width: availableWidth)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: QuickCreateCardSizePreferenceKey.self,
                        value: proxy.size
                    )
                }
            }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.contentSpacing) {
            Text("新建事项")
                .font(EditorFormStyle.title)

            TextField("标题", text: $model.draft.title)
                .textFieldStyle(.roundedBorder)
                .font(EditorFormStyle.body)
                .focused($titleFocused)
                .onChange(of: model.draft.title) { _, _ in ignoresParsedSchedule = false }

            if let parsed = recognizedParse,
               let summary = QuickAddPresentation.summary(parsed, defaultDate: model.draft.startDate) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10, weight: .semibold))
                    Text("保存为「\(parsed.title)」· \(summary)")
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("按原样") { ignoresParsedSchedule = true }
                        .buttonStyle(.borderless)
                        .help("不识别日期时间，标题原样保存")
                }
                .font(EditorFormStyle.caption)
                .foregroundStyle(theme.controlAccent)
                .accessibilityIdentifier("quick-add-recognized")
            }

            HStack(spacing: EditorFormStyle.categoryLabelSpacing) {
                Text("分类")
                    .font(EditorFormStyle.label)
                    .foregroundStyle(theme.secondaryText)
                EditorCategoryPicker(
                    categories: categories,
                    selectedID: model.draft.categoryID,
                    footerTitle: "管理分类…",
                    onSelect: { id in
                        categoryOption = id.uuidString
                        model.draft.categoryID = id
                    },
                    onFooter: {
                        presentCategoryManager(categoryID: model.draft.categoryID)
                    }
                )
                Spacer(minLength: 0)
            }

            scheduleBlock

            if !model.draft.repeatsWeekly {
                EditorReminderPicker(reminder: $model.draft.reminder, usesTime: model.draft.usesTime)
            }

            EditorMoreDetailsDisclosure(isExpanded: $showMoreDetails) {
                VStack(alignment: .leading, spacing: EditorFormStyle.contentSpacing) {
                    EditorRecurrenceModePicker(mode: recurrenceModeBinding)

                    if model.draft.repeatsWeekly {
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
                            scheduleFieldRow("直到") {
                                EditorDateChip(date: recurrenceEndBinding)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    MarkdownNotesEditor(text: $model.draft.notes, minHeight: 80, maxHeight: 130)
                }
            }

            if let message = localError ?? model.validationMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(EditorFormStyle.caption)
                        .foregroundStyle(theme.error)
                    if recoveryAction != nil {
                        Button("继续恢复", action: retryRecovery)
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onClose)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存", action: save)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.phase != .ready)
            }
        }
    }

    // MARK: - Schedule (compact)

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: EditorFormStyle.blockSpacing) {
            // 全天 / 定时 — short segmented control instead of a long checkbox label
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

            scheduleFieldRow("开始") {
                EditorDateChip(date: startDateBinding)
                if model.draft.usesTime {
                    EditorTimeChip(date: startTimeBinding)
                        .help("开始时间")
                }
                Spacer(minLength: 0)
            }

            scheduleFieldRow("结束") {
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.subtleBorder.opacity(0.16))
        )
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

    private func scheduleFieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(EditorFormStyle.label)
                .foregroundStyle(theme.secondaryText)
                .frame(width: EditorFormStyle.labelWidth, alignment: .leading)
            content()
        }
        .frame(minHeight: EditorFormStyle.fieldMinHeight)
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.startDate.editorDate },
            set: { model.draft.startDate = CalendarDate.editorDate(containing: $0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { model.draft.endDate.editorDate },
            set: { model.draft.endDate = CalendarDate.editorDate(containing: $0) }
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

    private var recurrenceModeBinding: Binding<ItemRecurrenceMode> {
        Binding(
            get: { model.draft.recurrenceMode },
            set: { model.draft.recurrenceMode = $0 }
        )
    }

    private var recurrenceEndEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.draft.recurrenceEndDate != nil },
            set: { enabled in
                model.draft.recurrenceEndDate = enabled ? model.draft.startDate : nil
            }
        )
    }

    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (model.draft.recurrenceEndDate ?? model.draft.startDate).editorDate },
            set: { model.draft.recurrenceEndDate = CalendarDate.editorDate(containing: $0) }
        )
    }

    private func presentCategoryManager(categoryID: UUID?) {
        if let onManageCategories {
            onManageCategories(categoryID)
        } else {
            openCategoryManager.callAsFunction(categoryID: categoryID)
        }
    }

    private var recognizedParse: QuickAddParse? {
        guard !ignoresParsedSchedule, !model.draft.repeatsWeekly else { return nil }
        let parse = QuickAddParser.parse(
            model.draft.title,
            today: CalendarDate.localDay(containing: Date(), in: .current)
        )
        guard parse.recognizedSchedule || parse.wantsReminder,
              parse.title != model.draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return parse
    }

    private func save() {
        localError = nil
        recoveryAction = nil
        guard store.phase == .ready else {
            localError = "日历尚未准备好，请稍候再试"
            return
        }
        if let parsed = recognizedParse, let applied = try? model.draft.applying(parsed) {
            model.draft = applied
        }
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
        let categoryName = categories.first(where: { $0.id == model.draft.categoryID })?.name
            ?? "未分类"
        let undoLabel = WorkspaceCreationFeedback.calendar(
            title: model.draft.title,
            date: model.draft.startDate,
            categoryName: categoryName
        )
        Task { @MainActor in
            do {
                apply(WorkspaceMutationOutcomePresenter.presentation(
                    for: try await store.sendCalendar(command, undoLabel: undoLabel)
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

}
