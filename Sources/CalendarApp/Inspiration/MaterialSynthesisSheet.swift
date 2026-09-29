import SwiftUI
import WorkspaceDomain

/// Pick two or more digested materials and turn them into one synthesis note.
struct MaterialSynthesisSheet: View {
    let store: WorkspaceStore
    let followUp: InspirationFollowUpService
    let onCreated: (NoteID) -> Void
    let onClose: () -> Void
    @State private var selected: [InspirationID] = []
    @State private var title = ""
    @State private var isRunning = false
    @State private var message: String?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    static func candidates(in state: WorkspaceState) -> [Inspiration] {
        state.inspirations.values
            .filter { state.materialDigests[$0.id]?.result != nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var candidates: [Inspiration] { Self.candidates(in: store.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("跨材料综合")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Text("选两份或更多已提炼的材料。综合会写成一篇新笔记，原材料和摘要都不改；写过“我的看法”的会作为出发点。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            if candidates.count < 2 {
                Label("至少需要两份已提炼的材料。先在灵感里对链接或文件点“提炼”。", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                List(candidates) { inspiration in
                    Toggle(isOn: binding(for: inspiration.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayTitle(inspiration)).lineLimit(1)
                            if inspiration.perspective?.hasAnswer == true {
                                Text("有我的看法").font(.system(size: 10)).foregroundStyle(theme.controlAccent)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(minHeight: 180, maxHeight: 280)
                TextField("笔记标题", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("生成综合笔记", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.count < 2 || isRunning || !followUp.isModelConfigured)
                    .keyboardShortcut(.defaultAction)
            }
            if !followUp.isModelConfigured {
                Text("在设置 › 摘要里选好模型后才能综合。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
    }

    private func binding(for id: InspirationID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.append(id) } else { selected.removeAll { $0 == id } }
                if title.isEmpty || title.hasPrefix("综合：") { title = defaultTitle }
            }
        )
    }

    private var defaultTitle: String {
        let names = selected.prefix(3).compactMap { store.state.inspirations[$0] }.map(displayTitle)
            .map { String($0.prefix(12)) }
        return names.isEmpty ? "" : "综合：" + names.joined(separator: " × ")
    }

    private func displayTitle(_ inspiration: Inspiration) -> String {
        inspiration.resolvedMetadata?.title
            ?? inspiration.rawFile?.displayName
            ?? inspiration.rawURL?.host
            ?? String((inspiration.rawText ?? "材料").prefix(30))
    }

    private func run() {
        isRunning = true
        message = nil
        let ids = selected
        let noteTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTitle : title
        Task {
            defer { isRunning = false }
            do {
                let noteID = try await followUp.synthesize(ids, title: noteTitle)
                onCreated(noteID)
            } catch let error as TextModelError {
                message = error.userMessage
            } catch {
                message = "综合没有完成，原材料不受影响。"
            }
        }
    }
}
