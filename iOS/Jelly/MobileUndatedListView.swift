import SwiftUI
import WorkspaceDomain

/// 以后再说 on the phone: same model and rules as the Mac panel.
struct MobileUndatedListView: View {
    @State private var model: UndatedListModel
    @Environment(\.dismiss) private var dismiss

    init(workspace: MobileWorkspace) {
        _model = State(initialValue: UndatedListModel(store: workspace.store))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("加一件还没定日期的事", text: $model.draft)
                        .onSubmit { Task { await model.add() } }
                        .submitLabel(.done)
                    if let recognition = model.draftRecognition {
                        Text(recognition).font(.caption).foregroundStyle(.tint)
                    }
                    if let message = model.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("写了日期或时间（如“周五下午3点”）会直接放进日历。")
                }
                Section {
                    if model.items.isEmpty {
                        Text("没有无日期的事").foregroundStyle(.secondary)
                    }
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if item.sourceInspirationID != nil {
                                Label("来自灵感", systemImage: "lightbulb").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("今天") { Task { await model.schedule(item.id, choice: .today) } }.tint(.accentColor)
                            Button("明天") { Task { await model.schedule(item.id, choice: .tomorrow) } }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) { Task { await model.delete(item.id) } }
                        }
                    }
                } footer: {
                    if !model.items.isEmpty { Text("向右滑安排到今天或明天，向左滑删除。") }
                }
            }
            .navigationTitle("以后再说")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
