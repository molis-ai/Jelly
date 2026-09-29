import SwiftUI
import WorkspaceDomain

/// Picker shown while typing `[[` in a note: existing notes whose title
/// matches, plus a row that creates a new note with the typed title.
struct NoteLinkMenu: View {
    let state: NoteLinkMenuState
    let onChoose: (NoteLinkMenuOption) -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.query.isEmpty ? "链接到笔记" : "链接到笔记：\(state.query)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            if state.options.isEmpty {
                Text("没有标题包含这些字的笔记")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            ForEach(Array(state.options.enumerated()), id: \.element.id) { index, option in
                Button {
                    onChoose(option)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: option))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 16)
                        Text(title(for: option))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        if case let .existing(candidate) = option, candidate.isArchived {
                            Text("已归档")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        index == state.selectedIndex ? theme.selectionFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: option))
                .accessibilityValue(index == state.selectedIndex ? "当前项" : "")
            }
            Text("↑↓ 选择 · 回车插入 · Esc 关闭")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
        .padding(6)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.elevatedSurface)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.subtleBorder, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("笔记链接菜单")
        .onExitCommand(perform: onDismiss)
    }

    private func title(for option: NoteLinkMenuOption) -> String {
        switch option {
        case let .existing(candidate): candidate.title
        case let .create(title): "新建笔记「\(title)」"
        }
    }

    private func icon(for option: NoteLinkMenuOption) -> String {
        switch option {
        case .existing: "doc.text"
        case .create: "plus"
        }
    }
}

/// Lists the notes that link to this one.
struct NoteBacklinksPopover: View {
    let backlinks: [NoteBacklink]
    let onOpen: (NoteID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("链接到这篇笔记的地方")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(backlinks) { backlink in
                        Button {
                            onOpen(backlink.sourceNoteID)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(backlink.sourceTitle)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(theme.primaryText)
                                        .lineLimit(1)
                                    if backlink.sourceIsArchived {
                                        Text("已归档")
                                            .font(.system(size: 11))
                                            .foregroundStyle(theme.secondaryText)
                                    }
                                }
                                Text(backlink.excerpt)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开 \(backlink.sourceTitle)")
                        .accessibilityHint(backlink.excerpt)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("反向链接")
    }
}
