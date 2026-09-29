import CalendarDomain
import SwiftUI
import WorkspaceDomain

enum NotesFolderExpansionPolicy {
    enum Action: Equatable {
        case none
        case activate
        case collapse
    }

    static func action(requestedExpansion: Bool, isActive: Bool) -> Action {
        if requestedExpansion { return .activate }
        return isActive ? .collapse : .none
    }

    static func rowClickAction(isExpanded: Bool, isActive: Bool) -> Action {
        if isExpanded, isActive { return .collapse }
        return .activate
    }
}

enum NotesBrowserSelectionPolicy {
    static func target(
        for note: Note,
        sourceLocation: NotesBrowserLocation?
    ) -> NotesBrowserLocation {
        if let sourceLocation { return sourceLocation }
        if note.archivedAt != nil { return .archived }
        return .category(note.categoryID)
    }
}

struct NoteBrowserView: View {
    @Bindable var viewModel: NotesWorkspaceViewModel
    let categories: [CalendarCategory]
    @Binding var location: NotesBrowserLocation
    @Binding var expandedLocations: Set<NotesBrowserLocation>
    let onSelect: (NoteID) async -> Void
    let onCreate: (UUID?) async -> Void
    let onMoveToCategory: (NoteID, UUID) async -> Bool
    let onActivateLocation: (NotesBrowserLocation) async -> Bool
    let onToggleBrowser: () -> Void
    let onShowCategoryManager: (UUID?) -> Void
    let noteCount: (NotesBrowserLocation) -> Int

    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var isSearching: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserHeader
            searchField
            browserContent
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .onChange(of: categories.map(\.id)) { _, ids in
            if case let .category(categoryID) = location, !ids.contains(categoryID) {
                location = .all
                expandedLocations = []
            }
            expandedLocations = expandedLocations.filter {
                if case let .category(categoryID) = $0 { return ids.contains(categoryID) }
                return true
            }
        }
        .onChange(of: viewModel.selectedNote?.archivedAt) { _, _ in
            alignLocationWithSelectedNote()
        }
        .onChange(of: viewModel.selectedNote?.categoryID) { _, categoryID in
            guard let categoryID, case .category = location else { return }
            location = .category(categoryID)
        }
    }

    private var browserHeader: some View {
        HStack(spacing: 6) {
            Text("笔记")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                let categoryID: UUID?
                if case let .category(selectedID) = location {
                    categoryID = selectedID
                } else {
                    categoryID = nil
                }
                Task { await onCreate(categoryID) }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.primaryText)
            .help("新建笔记")
            .accessibilityLabel("新建笔记")
            .accessibilityIdentifier("notes-new-note")

            Button(action: onToggleBrowser) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help("隐藏笔记列表")
            .accessibilityLabel("隐藏笔记列表")
        }
        .padding(.horizontal, 14)
        .frame(height: CalendarTheme.toolbarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            TextField("搜索标题和正文", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索笔记")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(theme.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.5), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var browserContent: some View {
        if isSearching {
            searchResults
        } else {
            folderTree
        }
    }

    private var folderTree: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("分类")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button {
                    let categoryID: UUID?
                    if case let .category(selectedID) = location {
                        categoryID = selectedID
                    } else {
                        categoryID = viewModel.selectedNote?.categoryID
                    }
                    onShowCategoryManager(categoryID)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("管理分类")
                .accessibilityLabel("管理分类")
            }
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    folderSection(title: "全部笔记", systemImage: "folder", target: .all)
                    ForEach(categories) { category in
                        folderSection(title: category.name, systemImage: "folder", target: .category(category.id))
                    }
                    folderSection(title: "归档", systemImage: "archivebox", target: .archived)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }

    private func folderSection(
        title: String,
        systemImage: String,
        target: NotesBrowserLocation
    ) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: target)) {
            folderNotes(target)
                .padding(.leading, 18)
                .padding(.bottom, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: expandedLocations.contains(target) ? "\(systemImage).fill" : systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: location == target ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(noteCount(target))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
            .foregroundStyle(location == target ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                if location == target {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.rangePreviewFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture {
                handleFolderRowClick(target)
            }
            .accessibilityLabel(title)
            .accessibilityIdentifier(target.accessibilityIdentifier)
            .accessibilityAddTraits(location == target ? .isSelected : [])
        }
        .disclosureGroupStyle(.automatic)
        .contextMenu {
            if target != .archived {
                Button(target == .all ? "新建笔记" : "在此新建笔记") {
                    let categoryID: UUID?
                    if case let .category(id) = target { categoryID = id } else { categoryID = nil }
                    Task { await onCreate(categoryID) }
                }
            }
            if case let .category(categoryID) = target {
                Button("管理分类…") { onShowCategoryManager(categoryID) }
            }
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard case let .category(categoryID) = target,
                  let rawID = payloads.first,
                  let uuid = UUID(uuidString: rawID)
            else { return false }
            Task { _ = await onMoveToCategory(NoteID(uuid), categoryID) }
            return true
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("搜索结果")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(viewModel.searchResults.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)

            ScrollView {
                LazyVStack(spacing: 2) {
                    noteRows(viewModel.searchResults, showsSearchContext: true, sourceLocation: nil)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }

    private func expansionBinding(for target: NotesBrowserLocation) -> Binding<Bool> {
        Binding(
            get: { expandedLocations.contains(target) },
            set: { requestedExpansion in
                switch NotesFolderExpansionPolicy.action(
                    requestedExpansion: requestedExpansion,
                    isActive: location == target
                ) {
                case .none:
                    break
                case .activate:
                    Task { await activate(target) }
                case .collapse:
                    expandedLocations.remove(target)
                }
            }
        )
    }

    private func handleFolderRowClick(_ target: NotesBrowserLocation) {
        switch NotesFolderExpansionPolicy.rowClickAction(
            isExpanded: expandedLocations.contains(target),
            isActive: location == target
        ) {
        case .none:
            break
        case .activate:
            Task { await activate(target) }
        case .collapse:
            expandedLocations.remove(target)
        }
    }

    @discardableResult
    private func activate(_ target: NotesBrowserLocation) async -> Bool {
        guard await onActivateLocation(target) else { return false }
        location = target
        switch target {
        case .all, .archived:
            expandedLocations = [target]
        case .category:
            expandedLocations.remove(.all)
            expandedLocations.remove(.archived)
            expandedLocations.insert(target)
        }
        return true
    }

    private func alignLocationWithSelectedNote() {
        guard let note = viewModel.selectedNote else { return }
        location = location.aligned(with: note)
        expandedLocations.insert(location)
    }

    @ViewBuilder
    private func folderNotes(_ target: NotesBrowserLocation) -> some View {
        let notes = viewModel.browserNotes(at: target)
        if notes.isEmpty {
            HStack(spacing: 8) {
                Text(target == .archived ? "归档为空" : "还没有笔记")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                if target != .archived {
                    Button("新建") {
                        Task {
                            let categoryID: UUID?
                            if case let .category(id) = target { categoryID = id } else { categoryID = nil }
                            await onCreate(categoryID)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        } else {
            noteRows(notes, showsSearchContext: false, sourceLocation: target)
        }
    }

    @ViewBuilder
    private func noteRows(
        _ notes: [Note],
        showsSearchContext: Bool,
        sourceLocation: NotesBrowserLocation?
    ) -> some View {
        if notes.isEmpty, showsSearchContext {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("没有找到匹配的笔记")
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ForEach(notes) { note in
                noteRow(note, showsSearchContext: showsSearchContext, sourceLocation: sourceLocation)
            }
        }
    }

    private func noteRow(
        _ note: Note,
        showsSearchContext: Bool,
        sourceLocation: NotesBrowserLocation?
    ) -> some View {
        Button {
            Task {
                let target = NotesBrowserSelectionPolicy.target(
                    for: note,
                    sourceLocation: sourceLocation
                )
                guard await activate(target) else { return }
                await onSelect(note.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title.isEmpty ? "无标题" : note.title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: viewModel.selectedNoteID == note.id ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)
                if showsSearchContext, let snippet = matchingSnippet(for: note) {
                    Text(highlighted(snippet))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    if note.isPinned { Image(systemName: "pin.fill") }
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if showsSearchContext {
                        Text("·")
                        Text(categoryName(for: note.categoryID)).lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if viewModel.selectedNoteID == note.id {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.rangePreviewFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.title.isEmpty ? "无标题笔记" : note.title)
        .accessibilityIdentifier("notes-note-\(note.id.rawValue.uuidString)")
        .accessibilityAddTraits(viewModel.selectedNoteID == note.id ? .isSelected : [])
        .draggable(note.id.rawValue.uuidString)
        .contextMenu {
            if note.archivedAt == nil {
                Button(note.isPinned ? "取消固定" : "固定到顶部") {
                    Task { _ = try? await viewModel.setPinned(note.id, !note.isPinned) }
                }
            }
            Menu("移动到分类") {
                ForEach(categories) { category in
                    Button(category.name) {
                        Task { _ = await onMoveToCategory(note.id, category.id) }
                    }
                    .disabled(category.id == note.categoryID || note.archivedAt != nil)
                }
            }
        }
    }

    private func categoryName(for categoryID: UUID) -> String {
        categories.first(where: { $0.id == categoryID })?.name ?? "未分类"
    }

    private func matchingSnippet(for note: Note) -> String? {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let paragraphs = note.document.blocks.map {
            $0.inlineContent.spans.map(\.text).joined()
        }
        return paragraphs.first(where: {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        })
    }

    private func highlighted(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceRange = source.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ), let range = Range(sourceRange, in: result) else { return result }
        result[range].backgroundColor = theme.controlAccent.opacity(0.18)
        result[range].foregroundColor = theme.primaryText
        return result
    }
}
