import SwiftUI
import CalendarDomain
import WorkspaceDomain

struct MobileCalendarView: View {
    @Bindable var workspace: MobileWorkspace
    @State private var day = CalendarDate.localDay(containing: Date(), in: .current)
    @State private var mode = "月"
    @State private var hiddenCategories: Set<UUID> = []
    @State private var editor: MobileItemEditorRequest?
    @State private var scopeEntry: ProjectedEntry?
    @State private var scopeSchedule: CalendarSchedule?
    @State private var showingScope = false
    @State private var showingReview = false
    @Environment(\.colorScheme) private var colorScheme
    private let modes = ["月", "周", "日", "日程"]
    private var theme: CalendarSemanticAppearance { CalendarTheme.appearance(for: colorScheme) }
    private var today: CalendarDate { .localDay(containing: Date(), in: .current) }
    private var days: [CalendarDate] {
        let start = day.addingDays(1 - day.weekday.rawValue)
        return (0..<7).map { start.addingDays($0) }
    }
    private var entries: [ProjectedEntry] { entries(on: day) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("日历视图", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                Menu {
                    Button("显示全部") { hiddenCategories.removeAll() }
                    ForEach(workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }) { category in
                        Button {
                            if hiddenCategories.contains(category.id) { hiddenCategories.remove(category.id) }
                            else { hiddenCategories.insert(category.id) }
                        } label: {
                            Label(category.name, systemImage: hiddenCategories.contains(category.id) ? "circle" : "checkmark.circle")
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("筛选分类")
            }.padding(.horizontal, 16)
            if mode == "月" {
                MobileMonthStream(workspace: workspace, selectedDay: $day, hiddenCategories: hiddenCategories,
                                  open: open, create: { create(on: $0) })
                agenda
            } else {
                HStack {
                    Button("上一页", systemImage: "chevron.left") { shift(-1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    Spacer()
                    Button("今天") { day = today }.frame(minHeight: 44)
                    Spacer()
                    Button("下一页", systemImage: "chevron.right") { shift(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.padding(.horizontal, 16)
                if mode == "日" { dateGrid }
                if mode == "周" || mode == "日" {
                    MobileTimeGrid(state: workspace.store.calendarState, selectedDay: $day, singleDay: mode == "日",
                                   hiddenCategoryIDs: hiddenCategories, isEditable: workspace.isReady,
                                   onOpen: open, onComplete: complete, onCreate: create,
                                   onReschedule: reschedule)
                } else { agenda }
            }
        }
        .jellySurface()
        .navigationTitle(mode == "月" ? "日历" : "\(day.year)年\(day.month)月")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(mode == "月" ? "本月回顾" : "本周回顾", systemImage: "chart.bar.xaxis") { showingReview = true }
                Spacer()
                Button { create(on: day) } label: {
                    Label("添加事项", systemImage: "plus")
                        .font(.headline).padding(.horizontal, 18).frame(minHeight: 48)
                        .foregroundStyle(theme.canvas).background(theme.controlAccent, in: Capsule())
                }.accessibilityIdentifier("add-calendar-item")
            }.padding(.horizontal, 20).padding(.vertical, 8).background(theme.canvas)
        }
        .sheet(item: $editor) { request in
            MobileItemEditor(workspace: workspace, request: request)
        }
        .sheet(isPresented: $showingReview) {
            MobileProgressView(workspace: workspace, period: mode == "月" ? .month : .week)
        }
        .confirmationDialog("修改重复事项", isPresented: $showingScope, titleVisibility: .visible) {
            Button("仅本次") { resolveScope(.onlyThis) }
            Button("本次及以后") { resolveScope(.thisAndFuture) }
            Button("取消", role: .cancel) { scopeEntry = nil; scopeSchedule = nil }
        }
    }

    private var dateGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
            ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { _, text in
                Text(text).font(.caption).foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity, minHeight: 24)
            }
            ForEach(days, id: \.self) { date in
                Button { day = date } label: {
                    VStack(spacing: 3) {
                        Text("\(date.day)").font(.body.weight(date == today ? .bold : .regular))
                            .foregroundStyle(date == day ? theme.canvas : date.month == day.month ? theme.primaryText : theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(date == day ? theme.controlAccent : date == today ? theme.todayFill : Color.clear, in: Circle())
                        HStack(spacing: 3) {
                            ForEach(Array(Set(entries(on: date).map(\.categoryID))).sorted(by: { $0.uuidString < $1.uuidString }).prefix(3), id: \.self) { id in
                                Circle().fill(categoryColor(id)).frame(width: 4, height: 4)
                            }
                        }.frame(height: 4)
                    }.frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(date.month)月\(date.day)日，\(entries(on: date).count)件事项")
                .accessibilityAddTraits(date == day ? .isSelected : [])
                .contextMenu { Button("在这天添加", systemImage: "plus") { create(on: date) } }
            }
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var agenda: some View {
        List {
            Section {
                if entries.isEmpty {
                    MobileEmptyState(title: "这一天，留些空间", symbol: "calendar", message: "点下方添加，安排一件想做的事。")
                        .listRowBackground(Color.clear)
                }
                ForEach(entries) { entry in
                    MobileCalendarRow(workspace: workspace, entry: entry, open: { open(entry) })
                        .listRowBackground(theme.elevatedSurface)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(entry.completedAt == nil ? "完成" : "重新打开", systemImage: entry.completedAt == nil ? "checkmark" : "arrow.uturn.backward") {
                                complete(entry)
                            }.tint(.green)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("编辑", systemImage: "pencil") { open(entry) }.tint(theme.controlAccent)
                        }
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { open(entry) }
                            Button("复制到今天", systemImage: "doc.on.doc") { copyToToday(entry) }
                        }
                }
                .onMove { offsets, destination in reorder(offsets, to: destination) }
            } header: {
                HStack {
                    Text("\(day.month)月\(day.day)日" + (day == today ? " · 今天" : ""))
                    Spacer()
                    Text("\(entries.filter { $0.completedAt != nil }.count)/\(entries.count)")
                }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
    }

    private func entries(on date: CalendarDate) -> [ProjectedEntry] {
        TimelineProjection.make(in: .init(start: date, end: date), state: workspace.store.calendarState,
                                hiddenCategoryIDs: hiddenCategories).entries
    }
    private func categoryColor(_ id: UUID) -> Color {
        CalendarTheme.categoryAccent(workspace.store.calendarState.categories[id]?.colorHex ?? "#8E8E93", appearance: colorScheme == .dark ? .dark : .light)
    }
    private func shift(_ direction: Int) {
        if mode == "月" {
            if let date = Calendar.current.date(byAdding: .month, value: direction, to: day.editorDate) { day = .editorDate(containing: date) }
        } else { day = day.addingDays(direction * (mode == "周" ? 7 : 1)) }
    }
    private func create(on date: CalendarDate) {
        editor = .init(mode: .create, draft: .newItem(from: date, through: date, categoryID: workspace.store.calendarState.uncategorizedID))
    }
    private func create(_ schedule: CalendarSchedule) {
        editor = .init(mode: .create, draft: .newItem(from: schedule.startDate, through: schedule.endDate,
            categoryID: workspace.store.calendarState.uncategorizedID, startTime: schedule.startTime, endTime: schedule.endTime))
    }
    private func open(_ entry: ProjectedEntry) {
        scopeSchedule = nil
        if case .occurrence = entry { scopeEntry = entry; showingScope = true }
        else { edit(entry, scope: .onlyThis) }
    }
    private func edit(_ entry: ProjectedEntry, scope: SeriesScope) {
        do { editor = try .existing(entry, scope: scope, state: workspace.state) }
        catch { workspace.errorMessage = error.localizedDescription }
    }
    private func reschedule(_ entry: ProjectedEntry, _ schedule: CalendarSchedule) {
        if case .occurrence = entry {
            scopeEntry = entry; scopeSchedule = schedule; showingScope = true
        } else { commitSchedule(entry, schedule, scope: .onlyThis) }
    }
    private func resolveScope(_ scope: SeriesScope) {
        guard let entry = scopeEntry else { return }
        let schedule = scopeSchedule
        scopeEntry = nil; scopeSchedule = nil
        if let schedule { commitSchedule(entry, schedule, scope: scope) }
        else { edit(entry, scope: scope) }
    }
    private func commitSchedule(_ entry: ProjectedEntry, _ schedule: CalendarSchedule, scope: SeriesScope) {
        // Retain the dragged entry as the baseline. A schedule changed while a
        // gesture/scope sheet was open must conflict instead of being replaced.
        let request: MobileItemEditorRequest
        switch entry {
        case let .item(item): request = .init(mode: .editItem(item), draft: .init(item: item))
        case let .occurrence(value):
            guard let series = workspace.state.calendar.recurrence.series[value.key.seriesID] else { return }
            request = .init(mode: .editOccurrence(series: series, key: value.key, scope: scope), draft: .init(occurrence: value, series: series))
        }
        Task {
            guard await workspace.flushEditors() else { return }
            do {
                let command = try MobileItemEditing.command(request: request,
                    edited: MobileItemEditing.applying(schedule, to: request.draft), state: workspace.state)
                await workspace.send(.calendar(command), label: "调整事项时间")
            } catch { workspace.errorMessage = error.localizedDescription }
        }
    }
    private func complete(_ entry: ProjectedEntry) {
        Task {
            guard await workspace.flushEditors() else { return }
            do {
                let command = try MobileItemEditing.completionCommand(for: entry.id, state: workspace.state)
                await workspace.send(command, label: "切换完成状态")
            } catch { workspace.errorMessage = error.localizedDescription }
        }
    }
    private func copyToToday(_ entry: ProjectedEntry) {
        Task {
            do {
                let source: ProjectedItem
                switch entry { case let .item(value): source = .item(value); case let .occurrence(value): source = .occurrence(value) }
                let item = try CalendarItemCopy.oneOff(from: source, to: today, id: UUID(), now: Date())
                await workspace.send(.calendar(.createItem(item)), label: "复制事项")
            } catch { workspace.errorMessage = error.localizedDescription }
        }
    }
    private func reorder(_ offsets: IndexSet, to destination: Int) {
        var values = entries
        values.move(fromOffsets: offsets, toOffset: destination)
        let movable = values.compactMap { entry -> UUID? in
            guard case let .item(item) = entry, item.schedule.startTime == nil, item.schedule.durationDays == 1 else { return nil }
            return item.id
        }
        Task { await workspace.send(.calendar(.reorderUntimedItems(on: day, orderedIDs: movable)), label: "排序事项") }
    }
}

struct MobileCalendarRow: View {
    let workspace: MobileWorkspace
    let entry: ProjectedEntry
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let category = workspace.store.calendarState.categories[entry.categoryID]
        let color = CalendarTheme.categoryAccent(category?.colorHex ?? "#8E8E93", appearance: colorScheme == .dark ? .dark : .light)
        HStack(spacing: 10) {
            Button {
                Task {
                    guard await workspace.flushEditors() else { return }
                    do {
                        let command = try MobileItemEditing.completionCommand(for: entry.id, state: workspace.state)
                        await workspace.send(command, label: "切换完成状态")
                    } catch { workspace.errorMessage = error.localizedDescription }
                }
            } label: {
                Image(systemName: entry.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(color).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(entry.completedAt == nil ? "标记完成" : "重新打开")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.body).foregroundStyle(CalendarTheme.appearance(for: colorScheme).primaryText)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(category?.name ?? "未分类")
                        if let time = entry.schedule.startTime {
                            Text(String(format: "%02d:%02d", time.value / 60, time.value % 60)).monospacedDigit()
                        }
                        if entry.schedule.durationDays > 1 { Text("至\(entry.schedule.endDate.month)/\(entry.schedule.endDate.day)") }
                        if entry.priority != .none { Text(entry.priority.title).fontWeight(.semibold) }
                        if case .occurrence = entry { Image(systemName: "repeat") }
                    }.font(.caption).foregroundStyle(color)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.opacity(entry.completedAt == nil ? 1 : 0.6)
    }
}

struct MobileItemEditor: View {
    let workspace: MobileWorkspace
    let request: MobileItemEditorRequest
    @StateObject private var model: ItemEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var deleteConfirmation = false
    @State private var discardConfirmation = false
    @State private var localMessage: String?

    init(workspace: MobileWorkspace, request: MobileItemEditorRequest) {
        self.workspace = workspace; self.request = request
        _model = StateObject(wrappedValue: .init(mode: request.mode, draft: request.draft))
    }
    private var isCreating: Bool { if case .create = request.mode { true } else { false } }
    private var hasPrimaryNote: Bool { MobileItemEditing.hasPrimaryNote(mode: request.mode, state: workspace.state) }
    private var canEditRecurrence: Bool {
        switch request.mode { case .create, .editOccurrence(_, _, .thisAndFuture): true; default: false }
    }
    private var isCompleted: Bool {
        switch request.mode {
        case .create: false
        case let .editItem(item): workspace.state.calendar.items[item.id]?.completedAt != nil
        case let .editOccurrence(_, key, _): workspace.state.calendar.recurrence.completions[key] != nil
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !isCreating {
                        Button(isCompleted ? "已完成 · 重新打开" : "标记完成",
                               systemImage: isCompleted ? "checkmark.circle.fill" : "circle") { toggleCompletion() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("calendar-completion")
                        if case .editOccurrence = request.mode {
                            Text("完成状态只影响这一次。日期和内容修改仍按所选范围保存。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("想做什么？", text: $model.draft.title, axis: .vertical)
                        .font(.title3).lineLimit(1...5).accessibilityIdentifier("item-title")
                    Picker("分类", selection: $model.draft.categoryID) {
                        ForEach(workspace.store.calendarState.categories.values.sorted { $0.sortIndex < $1.sortIndex }) { category in Text(category.name).tag(category.id) }
                    }
                    Picker("优先级", selection: $model.draft.priority) {
                        ForEach(ItemPriority.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("日期与时间") {
                    DatePicker("开始", selection: dateBinding(\.startDate), displayedComponents: .date)
                    DatePicker("结束", selection: dateBinding(\.endDate), displayedComponents: .date)
                    Toggle("指定时间", isOn: $model.draft.usesTime).onChange(of: model.draft.usesTime) { _, _ in model.usesTimeDidChange() }
                    if model.draft.usesTime {
                        DatePicker("开始时间", selection: timeBinding(\.startTime), displayedComponents: .hourAndMinute)
                            .onChange(of: model.draft.startTime) { _, _ in model.startTimeDidChange() }
                        DatePicker("结束时间", selection: timeBinding(\.endTime), displayedComponents: .hourAndMinute)
                    }
                }
                if !model.draft.repeatsWeekly {
                    Section {
                        Picker("提醒", selection: $model.draft.reminder) {
                            Text("不提醒").tag(ItemReminder?.none)
                            ForEach(MobileReminderOptions.options(usesTime: model.draft.usesTime), id: \.self) { option in
                                Text(option.title).tag(Optional(option))
                            }
                        }
                        .onChange(of: model.draft.usesTime) { _, _ in
                            model.draft.reminder = model.draft.reminder.map {
                                MobileReminderOptions.adapted($0, usesTime: model.draft.usesTime)
                            }
                        }
                    } footer: {
                        Text("到点时这台 iPhone 会通知你。Mac 上标的提醒通过“提醒事项”的 Jelly 列表送达。")
                    }
                }
                if canEditRecurrence {
                    Section("重复") {
                        Picker("重复规则", selection: $model.draft.recurrenceMode) {
                            ForEach(ItemRecurrenceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if model.draft.recurrenceMode == .weekly {
                            ForEach(Weekday.allCases, id: \.self) { weekday in
                                Toggle(["周一", "周二", "周三", "周四", "周五", "周六", "周日"][weekday.rawValue - 1], isOn: Binding(
                                    get: { model.draft.weekdays.contains(weekday) },
                                    set: { if $0 { model.draft.weekdays.insert(weekday) } else { model.draft.weekdays.remove(weekday) } }
                                ))
                            }
                        }
                        if model.draft.repeatsWeekly {
                            Toggle("设置结束日", isOn: Binding(get: { model.draft.recurrenceEndDate != nil }, set: { model.draft.recurrenceEndDate = $0 ? model.draft.startDate.addingDays(30) : nil }))
                            if let end = model.draft.recurrenceEndDate {
                                DatePicker("重复到", selection: Binding(get: { end.editorDate }, set: { model.draft.recurrenceEndDate = .editorDate(containing: $0) }), displayedComponents: .date)
                            }
                        }
                    }
                }
                if hasPrimaryNote {
                    Section("随记与主笔记") {
                        Text("这个事项的内容已由下方主笔记承载，请在主笔记中继续编辑。").foregroundStyle(.secondary)
                        if model.draft.notes != request.draft.notes {
                            Text("尚未保存的随记修改，复制后可粘贴到主笔记：").font(.caption)
                            Text(model.draft.notes).textSelection(.enabled)
                            Button("使用主笔记中的内容，放弃这里的随记修改") { model.draft.notes = request.draft.notes }
                        }
                    }
                } else {
                    Section("随记") { TextEditor(text: $model.draft.notes).frame(minHeight: 120).accessibilityLabel("事项随记") }
                }
                if !isCreating {
                    switch request.mode {
                    case let .editItem(item):
                        MobileCalendarRelations(workspace: workspace, target: .item(item.id))
                    case let .editOccurrence(_, key, _):
                        MobileCalendarRelations(workspace: workspace, target: .occurrence(key))
                    case .create: EmptyView()
                    }
                }
                if let message = localMessage ?? model.validationMessage { Section { Text(message).foregroundStyle(.red) } }
                if !isCreating { Section { Button("删除事项", role: .destructive) { deleteConfirmation = true } } }
            }
            .jellySurface().disabled(saving)
            .navigationTitle(isCreating ? "新事项" : "事项详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { save() }.disabled(saving)
                        .accessibilityIdentifier("save-calendar-item")
                }
            }
            .confirmationDialog("删除这个事项？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
            } message: { Text("删除后可使用撤销恢复。重复事项将按已选择的范围处理。") }
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { discard() }
            }
        }.interactiveDismissDisabled(true)
    }
    private func dateBinding(_ key: WritableKeyPath<ItemDraft, CalendarDate>) -> Binding<Date> {
        .init(get: { model.draft[keyPath: key].editorDate }, set: { model.draft[keyPath: key] = .editorDate(containing: $0) })
    }
    private func timeBinding(_ key: WritableKeyPath<ItemDraft, MinuteOfDay>) -> Binding<Date> {
        .init(get: { model.draft[keyPath: key].editorDate }, set: { model.draft[keyPath: key] = .editorMinute(containing: $0) })
    }
    private func toggleCompletion() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            guard await workspace.flushEditors() else {
                localMessage = workspace.errorMessage ?? "关联笔记尚未保存，完成状态没有改变。"
                return
            }
            do {
                let command = try MobileItemEditing.completionCommand(mode: request.mode, state: workspace.state)
                if await workspace.send(command, label: "切换完成状态") { localMessage = nil }
                else { localMessage = workspace.errorMessage ?? "完成状态未保存，请重试。" }
            } catch { localMessage = error.localizedDescription }
        }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                guard await workspace.flushEditors() else {
                    localMessage = workspace.errorMessage ?? "关联笔记仍有未保存的修改，输入已保留。"
                    return
                }
                let command = try MobileItemEditing.command(request: request, edited: model.draft, state: workspace.state)
                if await workspace.send(.calendar(command), label: isCreating ? "创建事项" : "编辑事项") { dismiss() }
                else { localMessage = workspace.errorMessage ?? "保存尚未确认，输入已保留。" }
            } catch { localMessage = (error as? ItemEditorError)?.message ?? error.localizedDescription }
        }
    }
    private func cancel() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            guard await workspace.flushEditors() else {
                localMessage = workspace.errorMessage ?? "关联笔记还有未保存的修改，输入已保留。"
                return
            }
            if model.draft == request.draft { dismiss() } else { discardConfirmation = true }
        }
    }
    private func discard() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            guard await workspace.flushEditors() else {
                localMessage = workspace.errorMessage ?? "关联笔记还有未保存的修改，输入已保留。"
                return
            }
            dismiss()
        }
    }
    private func delete() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                guard await workspace.flushEditors() else {
                    localMessage = workspace.errorMessage ?? "关联笔记还有未保存的修改，输入已保留。"
                    return
                }
                if await workspace.send(.calendar(try model.makeDeleteCommand(newSeriesID: UUID())), label: "删除事项") { dismiss() }
            } catch { localMessage = error.localizedDescription }
        }
    }
}

struct MobileProgressView: View {
    let workspace: MobileWorkspace
    let period: ProgressSummaryPeriod
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var confirmingMove = false
    @State private var editor: MobileItemEditorRequest?
    @State private var scopeEntry: ProjectedEntry?
    @State private var showingScope = false
    private var today: CalendarDate { .localDay(containing: Date(), in: .current) }
    private var stats: ProgressSummaryStats { ProgressSummaryEngine.stats(state: workspace.store.calendarState, period: period, today: today) }
    var body: some View {
        NavigationStack {
            List {
                Section { Text(ProgressSummaryEngine.report(from: stats).factualSummary).font(.headline) }
                Section("概览") {
                    ForEach(ProgressSummaryOverview.allCases) { metric in LabeledContent(metric.title, value: metric.value(in: stats)) }
                }
                Section("未完成") {
                    ForEach(stats.open) { fact in progressRow(fact, allowsSelection: true) }
                }
                Section("分类分布") {
                    ForEach(stats.categories) { category in LabeledContent(category.name, value: "\(category.completed)/\(category.total)") }
                }
                Section("已完成") { ForEach(stats.completed) { progressRow($0, allowsSelection: false) } }
            }.jellySurface().navigationTitle(period.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $editor) { MobileItemEditor(workspace: workspace, request: $0) }
                .confirmationDialog("修改重复事项", isPresented: $showingScope, titleVisibility: .visible) {
                    Button("仅本次") { if let scopeEntry { edit(scopeEntry, scope: .onlyThis) } }
                    Button("本次及以后") { if let scopeEntry { edit(scopeEntry, scope: .thisAndFuture) } }
                    Button("取消", role: .cancel) { scopeEntry = nil }
                }
                .safeAreaInset(edge: .bottom) {
                    Button("将选中的 \(selected.count) 件移到" + (period == .week ? "下周" : "下月")) { confirmingMove = true }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty).padding()
                }
                .confirmationDialog("确认批量改期？", isPresented: $confirmingMove, titleVisibility: .visible) {
                    Button("确认改期") {
                        let destination: CalendarDate
                        if period == .week { destination = today.addingDays(8 - today.weekday.rawValue) }
                        else {
                            let first = CalendarDate(year: today.year, month: today.month, day: 1)!
                            destination = .editorDate(containing: Calendar.current.date(byAdding: .month, value: 1, to: first.editorDate)!)
                        }
                        Task {
                            if await workspace.send(.calendar(.moveItems(Array(selected), to: destination)), label: "批量改期") { selected.removeAll() }
                        }
                    }
                } message: { Text("只移动选中的一次性事项，重复事项保持原样。可一次撤销。") }
                .onChange(of: workspace.store.statePublicationGeneration) { _, _ in
                    selected.formIntersection(Set(stats.open.compactMap(\.calendarItemID)))
                }
        }
    }
    private func progressRow(_ fact: ProgressItemFact, allowsSelection: Bool) -> some View {
        HStack(spacing: 8) {
            if allowsSelection, let id = fact.calendarItemID {
                Button {
                    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                } label: {
                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle").frame(width: 44, height: 44)
                }.buttonStyle(.borderless)
                    .accessibilityLabel((selected.contains(id) ? "取消选择迁移：" : "选择迁移：") + fact.title)
            } else if fact.calendarItemID == nil {
                Image(systemName: "repeat").frame(width: 44)
            }
            Button { open(fact) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.title).foregroundStyle(.primary)
                    Text("\(fact.date.month)月\(fact.date.day)日" + (fact.isOverdue ? " · 已延期" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.borderless).accessibilityLabel("打开事项：" + fact.title)
        }
    }
    private func open(_ fact: ProgressItemFact) {
        // Facts retain the canonical ProjectedItem identifier, including the
        // series UUID and original occurrence date. Titles/dates are not keys.
        let projection = TimelineProjection.make(in: .init(start: stats.range.start, end: stats.range.end), state: workspace.state.calendar, hiddenCategoryIDs: [])
        guard let entry = projection.entries.first(where: { ProjectedItem(entry: $0).id == fact.id }) else {
            workspace.errorMessage = "事项已发生变化，请重新打开回顾。"
            return
        }
        if case .occurrence = entry { scopeEntry = entry; showingScope = true }
        else { edit(entry, scope: .onlyThis) }
    }
    private func edit(_ entry: ProjectedEntry, scope: SeriesScope) {
        do { editor = try .existing(entry, scope: scope, state: workspace.state) }
        catch { workspace.errorMessage = error.localizedDescription }
    }

}
