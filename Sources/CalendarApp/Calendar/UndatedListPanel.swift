import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// Right-hand panel in the calendar: things without a day yet.
struct UndatedListPanel: View {
    @Bindable var model: UndatedListModel
    let categories: [UUID: CalendarCategory]
    let onClose: () -> Void
    @State private var editingID: UUID?
    @State private var editingTitle = ""
    @FocusState private var addFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 280

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("以后再说")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(model.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.right")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("收起无日期清单")
            }
            .padding(.horizontal, 14)
            .frame(height: CalendarTheme.toolbarHeight)

            VStack(alignment: .leading, spacing: 4) {
                TextField("加一件还没定日期的事", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit { Task { await model.add() } }
                    .accessibilityIdentifier("undated-add-field")
                if let recognition = model.draftRecognition {
                    Text(recognition)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.controlAccent)
                } else {
                    Text("写了日期或时间（如“周五下午3点”）会直接放进日历。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                if let message = model.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider().overlay(theme.separator.opacity(0.6))

            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 18))
                    Text("没有无日期的事")
                        .font(.system(size: 12))
                    Text("灵感回顾里选“放进无日期清单”的也会在这里。")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.items) { item in
                            row(item)
                                .padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.elevatedSurface)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.separator).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("无日期清单")
    }

    private func row(_ item: UndatedItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(CalendarTheme.categoryColor(categories[item.categoryID]?.colorHex ?? "#8E8E93"))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                if editingID == item.id {
                    TextField("标题", text: $editingTitle)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let id = item.id
                            let title = editingTitle
                            editingID = nil
                            Task { await model.rename(id, to: title) }
                        }
                } else {
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .onTapGesture(count: 2) {
                            editingTitle = item.title
                            editingID = item.id
                        }
                }
                if item.sourceInspirationID != nil {
                    Label("来自灵感", systemImage: "lightbulb")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("今天") { Task { await model.schedule(item.id, choice: .today) } }
                Button("明天") { Task { await model.schedule(item.id, choice: .tomorrow) } }
                Divider()
                Button("改标题") {
                    editingTitle = item.title
                    editingID = item.id
                }
                Button("删除", role: .destructive) { Task { await model.delete(item.id) } }
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .foregroundStyle(theme.controlAccent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(theme.controlAccent)
            .fixedSize()
            .help("安排到某天")
            .accessibilityLabel("安排「\(item.title)」")
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("安排到今天") { Task { await model.schedule(item.id, choice: .today) } }
            Button("安排到明天") { Task { await model.schedule(item.id, choice: .tomorrow) } }
            Button("删除", role: .destructive) { Task { await model.delete(item.id) } }
        }
    }
}
