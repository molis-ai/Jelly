import AppKit
import CalendarDomain
import SwiftUI

enum CategoryManagerInitialSelection {
    static func resolve(
        preferredCategoryID: UUID?,
        orderedCategories: [CalendarCategory]
    ) -> UUID? {
        if let preferredCategoryID,
           orderedCategories.contains(where: { $0.id == preferredCategoryID }) {
            return preferredCategoryID
        }
        return orderedCategories.first?.id
    }
}

/// Category manager — same visual language as the item editor (compact, warm, non-system).
struct CategoryManagerView: View {
    let store: WorkspaceStore
    let initialCategoryID: UUID?
    var onClose: (() -> Void)? = nil
    @StateObject private var model: CategoryManagerViewModel
    @State private var editingCategoryID: UUID?
    @State private var categoryBeforeCreatingID: UUID?
    @State private var isCreating = false
    @State private var showAdvancedColors = false
    @State private var localError: String?
    @State private var attemptedSave = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    init(
        store: WorkspaceStore,
        initialCategoryID: UUID? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self.initialCategoryID = initialCategoryID
        self.onClose = onClose
        _model = StateObject(wrappedValue: CategoryManagerViewModel(store: store))
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 200)
            Rectangle()
                .fill(theme.separator.opacity(0.45))
                .frame(width: 1)
            editor
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Single elevated surface like the item editor — avoids muddy nested grays.
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog(
            "删除分类",
            isPresented: deleteDialogPresented,
            presenting: model.categoryToDelete
        ) { category in
            Button("删除并转入未分类", role: .destructive) {
                confirmDelete(category)
            }
            Button("取消", role: .cancel) {
                model.categoryToDelete = nil
            }
        } message: { category in
            Text("“\(category.name)”中的日历事项、笔记和灵感会一并转入“未分类”。")
        }
        .onChange(of: store.calendarState) { _, state in
            if let editingCategoryID {
                if let category = state.categories[editingCategoryID] {
                    model.synchronizeDraftFromStore(category)
                } else {
                    startCreating()
                }
            }
        }
        .onAppear {
            guard editingCategoryID == nil, !isCreating,
                  let categoryID = CategoryManagerInitialSelection.resolve(
                    preferredCategoryID: initialCategoryID,
                    orderedCategories: orderedCategories
                  ),
                  let category = store.calendarState.categories[categoryID]
            else { return }
                select(category)
        }
    }

    // MARK: - Sidebar

    private var categoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("分类")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                toolbarIconButton(
                    systemName: "plus",
                    help: "新建分类",
                    emphasized: isCreating
                ) {
                    startCreating()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            thinRule

            ScrollView {
                LazyVStack(spacing: 6) {
                    if isCreating {
                        creatingRow
                    }
                    ForEach(orderedCategories) { category in
                        categoryRow(category)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        // Slightly quieter than the editor column.
        .background(theme.canvas.opacity(colorScheme == .dark ? 0.55 : 0.35))
    }

    private var creatingRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CalendarTheme.categoryColor(model.draftColorHex))
                .frame(width: 10, height: 10)
            Text(model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "新分类…"
                : model.draftName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("编辑中")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.controlAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.controlAccent.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.selectionFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.controlAccent.opacity(0.35), lineWidth: 1)
        }
    }

    private func categoryRow(_ category: CalendarCategory) -> some View {
        let selected = category.id == editingCategoryID && !isCreating
        let previewName = CategoryRowPreview.name(
            stored: category.name,
            draft: model.draftName,
            isLive: selected
        )
        let previewHex = CategoryRowPreview.colorHex(
            stored: category.colorHex,
            draft: model.draftColorHex,
            isLive: selected
        )
        return Button {
            select(category)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(CalendarTheme.categoryColor(previewHex))
                    .frame(width: 10, height: 10)
                Text(previewName)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(
                        selected && previewName == CategoryRowPreview.emptyNamePlaceholder
                            ? theme.secondaryText
                            : theme.primaryText
                    )
                Spacer(minLength: 0)
                Text("\(usageCount(for: category))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                if category.id == store.calendarState.uncategorizedID {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText.opacity(0.55))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? theme.selectionFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .draggable(category.id.uuidString)
        .dropDestination(for: String.self) { payloads, _ in
            guard let rawID = payloads.first,
                  let draggedID = UUID(uuidString: rawID),
                  draggedID != category.id
            else { return false }
            moveCategory(draggedID, before: category.id)
            return true
        }
        .help("拖动可调整分类顺序")
    }

    private func toolbarIconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    disabled
                        ? theme.secondaryText.opacity(0.3)
                        : (emphasized ? theme.controlAccent : theme.secondaryText)
                )
                .frame(width: 28, height: 28)
                .background(
                    (emphasized ? theme.controlAccent.opacity(0.18) : theme.subtleBorder.opacity(disabled ? 0.08 : 0.22)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader
            thinRule
            VStack(alignment: .leading, spacing: 16) {
                if isCreating || editingCategory != nil {
                    usageOverview
                    nameBlock
                    colorBlock
                } else {
                    emptyCategoriesHint
                }

                if let message = userFacingMessage {
                    Text(message.text)
                        .font(.system(size: 12))
                        .foregroundStyle(message.isError ? theme.error : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)

            thinRule
            editorFooter
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCreating ? "新建分类" : "管理分类")
                    .font(.system(size: 13, weight: .semibold))
                if let editingCategory {
                    Text("正在管理“\(editingCategory.name)”")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.subtleBorder.opacity(0.3), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Matches item editor: destructive left, primary actions right.
    private var editorFooter: some View {
        HStack(spacing: 8) {
            if editingCategory != nil {
                Button("删除", role: .destructive, action: beginDelete)
                    .controlSize(.small)
                    .disabled(store.phase != .ready)
            }
            Spacer(minLength: 0)
            Button("取消") {
                if isCreating {
                    cancelCreating()
                } else {
                    close()
                }
            }
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
            Button(isCreating ? "创建" : "保存", action: save)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(isSaveDisabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var emptyCategoriesHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有自定义分类")
                .font(.system(size: 13, weight: .semibold))
            Text("点左上角 + 新建。没有分类的事项会用系统灰色，不必单独管理。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    /// Primary feedback: how the category will look on the calendar.
    private var livePreviewHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("月历预览")
            HStack(spacing: 12) {
                previewChip(appearance: .light, caption: "浅色")
                previewChip(appearance: .dark, caption: "深色")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private var usageOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("使用情况")
            HStack(spacing: 10) {
                usagePill("日历", value: editingCategory.map { calendarUsageCount(for: $0) } ?? 0)
                usagePill("笔记", value: editingCategory.map { noteUsageCount(for: $0) } ?? 0)
                usagePill("灵感", value: editingCategory.map { inspirationUsageCount(for: $0) } ?? 0)
            }
            if isCreating {
                Text("创建后，日历事项、笔记和灵感都可以使用这个分类。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private func usagePill(_ title: String, value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(theme.subtleBorder.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    private func previewChip(appearance: CalendarAppearance, caption: String) -> some View {
        let previewTheme = appearance == .light ? CalendarTheme.light : CalendarTheme.dark
        let roles = try? CategoryColorResolver.roles(for: model.draftColorHex, appearance: appearance)
        let canvasHex = roles?.canvas.hex ?? (appearance == .light
            ? CalendarTheme.previewLightCanvasHex
            : CalendarTheme.previewDarkCanvasHex)
        let textHex = roles?.text.hex ?? (appearance == .light
            ? CalendarTheme.previewLightTextHex
            : CalendarTheme.previewDarkTextHex)
        let accentColor = roles.map { CalendarTheme.categoryColor($0.accent) }
            ?? CalendarTheme.categoryColor(model.draftColorHex)
        let backgroundColor = roles.map { CalendarTheme.categoryColor($0.softBackground) }
            ?? CalendarTheme.categoryColor(canvasHex)
        let label = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(previewTheme.secondaryText)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 3, height: 15)
                Text(label.isEmpty ? "分类事项" : label)
                    .lineLimit(1)
                    .foregroundStyle(CalendarTheme.categoryColor(textHex))
                Spacer(minLength: 0)
            }
            .font(CalendarTheme.itemFont)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CalendarTheme.categoryColor(canvasHex),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(previewTheme.subtleBorder.opacity(0.55), lineWidth: 1)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("名称")
            TextField("例如：学习、运动、副业", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($nameFocused)
                .disabled(isProtectedCategory)
                .onChange(of: model.draftName) { _, _ in
                    if attemptedSave { attemptedSave = false }
                    localError = nil
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private var colorBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("颜色")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 30), spacing: 10), count: 8),
                spacing: 10
            ) {
                ForEach(CategoryPalette.family(id: .basic).presets) { preset in
                    let selected = model.draftColorHex.uppercased() == preset.hex
                    Button {
                        model.selectPreset(preset.hex)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(CalendarTheme.categoryColor(preset.hex))
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(swatchCheckColor(for: preset.hex))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle().stroke(
                                selected ? theme.primaryText.opacity(0.9) : theme.subtleBorder.opacity(0.4),
                                lineWidth: selected ? 2 : 1
                            )
                        }
                        .shadow(
                            color: selected ? CalendarTheme.categoryColor(preset.hex).opacity(0.4) : .clear,
                            radius: 5,
                            y: 1
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isProtectedCategory)
                    .accessibilityLabel("选择\(preset.accessibilityName)")
                    .accessibilityValue(selected ? "已选中" : "未选中")
                }
            }

            DisclosureGroup("自定义颜色", isExpanded: $showAdvancedColors) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CategoryPalette.families.dropFirst()) { family in
                                Button(family.name) { model.selectFamily(family.id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 30), spacing: 10), count: 8),
                        spacing: 10
                    ) {
                        ForEach(selectedFamily.presets) { preset in
                            Button { model.selectPreset(preset.hex) } label: {
                                Circle()
                                    .fill(CalendarTheme.categoryColor(preset.hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if model.draftColorHex.uppercased() == preset.hex {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(swatchCheckColor(for: preset.hex))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(isProtectedCategory)
                            .accessibilityLabel("选择\(familyName(for: preset.hex))的\(preset.accessibilityName)")
                        }
                    }
                    HStack(spacing: 10) {
                        TextField("#RRGGBB", text: $model.draftColorHex)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(isProtectedCategory)
                            .onChange(of: model.draftColorHex) { _, hex in
                                model.normalizeDraftColorIfComplete(hex)
                            }
                        ColorPicker("取色", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .disabled(isProtectedCategory)
                    }
                }
                .padding(.top, 10)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    // MARK: - Shared chrome

    private var thinRule: some View {
        Rectangle()
            .fill(theme.separator.opacity(0.45))
            .frame(height: 1)
    }

    /// Soft fill only — matches item editor blocks (no heavy double borders).
    private var fieldBlockBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.subtleBorder.opacity(colorScheme == .dark ? 0.16 : 0.14))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }

    // MARK: - Validation display

    /// Only show hard errors after the user tries to save (or real save failures).
    private var userFacingMessage: (text: String, isError: Bool)? {
        if let localError {
            return (localError, true)
        }
        guard attemptedSave, let validationError else { return nil }
        switch validationError {
        case .emptyName:
            return ("请填写分类名称。", true)
        case .duplicateName:
            return ("已有同名分类，请换一个名称。", true)
        case .invalidColor:
            return ("颜色必须是 #RRGGBB 格式。", true)
        case .insufficientContrast:
            return ("这个颜色在浅色或深色下不够清晰，请换一个。", true)
        default:
            return ("当前分类不能保存。", true)
        }
    }

    // MARK: - Model helpers

    private var colorBinding: Binding<Color> {
        Binding(
            get: { CalendarTheme.categoryColor(model.draftColorHex) },
            set: { color in
                if let hex = Self.hexString(from: color) {
                    model.applyDraftColor(hex)
                }
            }
        )
    }

    private var selectedFamily: CategoryColorFamily {
        CategoryPalette.family(id: model.selectedFamilyID)
    }

    private func swatchCheckColor(for hex: String) -> Color {
        guard let base = try? SRGBColor(hex: hex),
              let warmLight = try? SRGBColor(hex: CalendarTheme.dark.primaryTextHex),
              let warmDark = try? SRGBColor(hex: CalendarTheme.light.primaryTextHex)
        else {
            return theme.primaryText
        }
        return base.contrastRatio(with: warmLight) >= base.contrastRatio(with: warmDark)
            ? CalendarTheme.dark.primaryText
            : CalendarTheme.light.primaryText
    }

    private var editingCategory: CalendarCategory? {
        editingCategoryID.flatMap { store.calendarState.categories[$0] }
    }

    private var isProtectedCategory: Bool {
        editingCategoryID == store.calendarState.uncategorizedID
    }

    private var orderedCategories: [CalendarCategory] {
        CategoryReorderMove.visibleCategories(
            Array(store.calendarState.categories.values),
            uncategorizedID: store.calendarState.uncategorizedID
        )
    }

    private var validationError: CategoryManagerError? {
        guard !isProtectedCategory else { return nil }
        let name = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .emptyName }
        let nameKey = name.lowercased()
        guard !store.calendarState.categories.values.contains(where: {
            $0.id != editingCategoryID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == nameKey
        }) else {
            return .duplicateName
        }
        do {
            try CategoryColorValidator.validateReadableInBothAppearances(model.draftColorHex)
            return nil
        } catch let error as CategoryManagerError {
            return error
        } catch {
            return .invalidColor
        }
    }

    private var isSaveDisabled: Bool {
        (!isCreating && editingCategory == nil) || store.phase != .ready
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { model.categoryToDelete != nil },
            set: {
                if !$0 {
                    model.categoryToDelete = nil
                }
            }
        )
    }

    private func select(_ category: CalendarCategory) {
        guard category.id != store.calendarState.uncategorizedID else { return }
        isCreating = false
        categoryBeforeCreatingID = nil
        editingCategoryID = category.id
        model.beginEditing(category)
        localError = nil
        attemptedSave = false
        nameFocused = true
    }

    private func startCreating() {
        if !isCreating {
            categoryBeforeCreatingID = editingCategoryID
        }
        isCreating = true
        editingCategoryID = nil
        model.beginCreating()
        localError = nil
        attemptedSave = false
        nameFocused = true
    }

    private func save() {
        attemptedSave = true
        localError = nil
        if validationError != nil { return }
        Task {
            do {
                let presentation: WorkspaceMutationPresentation
                if let category = editingCategory, !isCreating {
                    presentation = try await model.update(category)
                } else {
                    presentation = try await model.create()
                }
                guard presentation.allowsDismissal else {
                    localError = presentation.message
                    return
                }
                attemptedSave = false
                close()
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func beginDelete() {
        guard let category = editingCategory, category.id != store.calendarState.uncategorizedID else { return }
        model.categoryToDelete = category
    }

    private func confirmDelete(_ category: CalendarCategory) {
        localError = nil
        Task {
            do {
                let presentation = try await model.deleteConfirmed(category: category)
                guard presentation.allowsDismissal else {
                    localError = presentation.message
                    return
                }
                selectFallbackCategory()
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func cancelCreating() {
        let categoryToRestoreID = CategoryManagerInitialSelection.resolve(
            preferredCategoryID: categoryBeforeCreatingID,
            orderedCategories: orderedCategories
        )
        categoryBeforeCreatingID = nil
        isCreating = false
        if let categoryToRestoreID,
           let categoryToRestore = store.calendarState.categories[categoryToRestoreID] {
            select(categoryToRestore)
        } else {
            selectFallbackCategory()
        }
    }

    private func selectFallbackCategory() {
        if let category = orderedCategories.first {
            select(category)
        } else {
            editingCategoryID = nil
        }
    }

    private func calendarUsageCount(for category: CalendarCategory) -> Int {
        store.calendarState.items.values.filter { $0.categoryID == category.id }.count
            + store.calendarState.recurrence.series.values.filter { $0.categoryID == category.id }.count
    }

    private func noteUsageCount(for category: CalendarCategory) -> Int {
        store.state.notes.values.filter { $0.categoryID == category.id }.count
    }

    private func inspirationUsageCount(for category: CalendarCategory) -> Int {
        store.state.inspirations.values.filter { $0.categoryID == category.id }.count
    }

    private func usageCount(for category: CalendarCategory) -> Int {
        calendarUsageCount(for: category) + noteUsageCount(for: category) + inspirationUsageCount(for: category)
    }

    private func moveCategory(_ draggedID: UUID, before targetID: UUID) {
        var visibleIDs = orderedCategories.map(\.id)
        guard draggedID != store.calendarState.uncategorizedID,
              targetID != store.calendarState.uncategorizedID,
              let sourceIndex = visibleIDs.firstIndex(of: draggedID),
              let targetIndex = visibleIDs.firstIndex(of: targetID)
        else { return }
        visibleIDs.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        visibleIDs.insert(draggedID, at: insertionIndex)
        let currentlyOrdered = store.calendarState.categories.values
            .sorted {
                $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
            }
            .map(\.id)
        let ids = CategoryReorderMove.persistedOrder(
            visibleIDs: visibleIDs,
            uncategorizedID: store.calendarState.uncategorizedID,
            currentlyOrderedIDs: currentlyOrdered
        )
        Task {
            do {
                let presentation = try await model.reorder(ids)
                if !presentation.allowsDismissal { localError = presentation.message }
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func familyName(for hex: String) -> String {
        CategoryPalette.families.first(where: { $0.colors.contains(hex) })?.name ?? "自定义"
    }

    private func message(for error: Error) -> String {
        switch error as? CategoryManagerError {
        case .emptyName:
            return "请填写分类名称。"
        case .duplicateName:
            return "已有同名分类，请换一个名称。"
        case .invalidColor:
            return "颜色必须是 #RRGGBB 格式。"
        case .insufficientContrast:
            return "这个颜色在浅色或深色下文字不够清晰，请换一个颜色。"
        case .protectedCategory:
            return "“未分类”是系统分类，不能修改或删除。"
        case nil:
            return WorkspaceMutationOutcomePresenter.message(for: error)
        }
    }

    private static func hexString(from color: Color) -> String? {
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB)
        guard let rgb else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Self.byte(rgb.redComponent),
            Self.byte(rgb.greenComponent),
            Self.byte(rgb.blueComponent)
        )
    }

    private static func byte(_ component: CGFloat) -> Int {
        min(255, max(0, Int((component * 255).rounded())))
    }
}
