import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// One pass through the inspirations that are due. The queue is fixed when
/// the pass starts so items do not shuffle under the user's hand.
@MainActor
@Observable
final class InspirationReviewSession {
    struct Tally: Equatable {
        var kept = 0
        var scheduled = 0
        var discarded = 0
        var skipped = 0
    }

    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    private(set) var queue: [InspirationID]
    private(set) var index = 0
    private(set) var tally = Tally()
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    init(
        store: WorkspaceStore,
        schedule: ReviewSchedule = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.clock = clock
        queue = InspirationReviewQueue.due(in: store.state, now: clock(), schedule: schedule).map(\.id)
    }

    var isFinished: Bool { index >= queue.count }

    var current: Inspiration? {
        guard !isFinished else { return nil }
        return store.state.inspirations[queue[index]]
    }

    var progressText: String { "\(min(index + 1, queue.count)) / \(queue.count)" }

    func keep() async {
        await act { id in
            try await self.store.sendWorkspace(.reviewInspiration(id, at: self.clock()), undoLabel: "回顾：留着")
        } onSuccess: { $0.kept += 1 }
    }

    func schedule(_ choice: InspirationScheduleChoice) async {
        guard let inspiration = current else { return }
        isWorking = true
        defer { isWorking = false }
        if await InspirationViewModel.schedule(inspiration, choice: choice, store: store, now: clock()) {
            tally.scheduled += 1
            advance()
        } else {
            errorMessage = "没能变成待办，这条灵感还在。"
        }
    }

    func discard() async {
        await act { id in
            try await self.store.sendWorkspace(.archiveInspiration(id, at: self.clock()), undoLabel: "回顾：丢掉")
        } onSuccess: { $0.discarded += 1 }
    }

    func skip() {
        guard !isFinished else { return }
        tally.skipped += 1
        advance()
    }

    private func act(
        _ send: @escaping (InspirationID) async throws -> WorkspaceTransactionOutcome,
        onSuccess: (inout Tally) -> Void
    ) async {
        guard let id = current?.id else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await send(id)
            switch outcome {
            case .committed, .noChange:
                onSuccess(&tally)
                advance()
            default:
                errorMessage = "这一步没有保存，请再试一次。"
            }
        } catch {
            errorMessage = "这一步没有保存，请再试一次。"
        }
    }

    private func advance() {
        errorMessage = nil
        index += 1
        // Skip items that changed elsewhere meanwhile (e.g. converted on the page).
        while let id = queue[safe: index], store.state.inspirations[id]?.lifecycle != .active {
            index += 1
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct InspirationReviewSheet: View {
    @State private var session: InspirationReviewSession
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(store: WorkspaceStore, onClose: @escaping () -> Void) {
        _session = State(initialValue: InspirationReviewSession(store: store))
        self.onClose = onClose
    }

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("回顾灵感")
                    .font(.system(size: 17, weight: .semibold))
                if !session.queue.isEmpty, !session.isFinished {
                    Text(session.progressText)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if let inspiration = session.current {
                card(inspiration)
                actions
                if let message = session.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } else {
                finished
            }
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 340, alignment: .top)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
    }

    private func card(_ inspiration: Inspiration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(inspiration.createdAt.formatted(.dateTime.month().day())) 记下")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(primaryText(inspiration))
                .font(.system(size: 16))
                .lineSpacing(5)
                .lineLimit(10)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let host = inspiration.rawURL?.host {
                Label(host, systemImage: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            if let expansion = inspiration.expansion {
                Divider()
                Text(expansion.supplement)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                ForEach(expansion.directions.filter { $0.decision != .ignored }) { direction in
                    Label(direction.text, systemImage: direction.decision == .adopted ? "checkmark" : "arrow.turn.down.right")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.elevatedSurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspiration-review-card")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await session.keep() }
            } label: {
                Label("留着", systemImage: "tray")
            }
            .keyboardShortcut("k", modifiers: [])
            .help("下一轮回顾再看（K）")

            Menu {
                Button("今天") { Task { await session.schedule(.today) } }
                Button("明天") { Task { await session.schedule(.tomorrow) } }
                Button("放进无日期清单") { Task { await session.schedule(.undated) } }
            } label: {
                Label("变成待办", systemImage: "calendar.badge.plus")
            } primaryAction: {
                Task { await session.schedule(.today) }
            }
            .fixedSize()
            .help("点按安排到今天，展开可选明天或无日期（T）")

            Button(role: .destructive) {
                Task { await session.discard() }
            } label: {
                Label("丢掉", systemImage: "archivebox")
            }
            .keyboardShortcut("d", modifiers: [])
            .help("归档，可在“已归档”里恢复（D）")

            Spacer()
            Button("跳过") { session.skip() }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .controlSize(.large)
        .disabled(session.isWorking)
        .background {
            // "T" for the default to-do action without stealing the menu's click.
            Button("") { Task { await session.schedule(.today) } }
                .keyboardShortcut("t", modifiers: [])
                .hidden()
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.queue.isEmpty {
                Label("现在没有需要回顾的灵感。", systemImage: "checkmark.circle")
                Text("收下超过一天、还没变成笔记或待办的灵感会在这里出现；选“留着”的一周后再回来。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                Label("这一轮看完了", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                let tally = session.tally
                Text("留着 \(tally.kept) · 变成待办 \(tally.scheduled) · 丢掉 \(tally.discarded) · 跳过 \(tally.skipped)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
            }
            HStack {
                Spacer()
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func primaryText(_ inspiration: Inspiration) -> String {
        if let text = inspiration.rawText, !text.isEmpty { return text }
        if let title = inspiration.resolvedMetadata?.title, !title.isEmpty { return title }
        if let file = inspiration.rawFile { return file.displayName }
        return inspiration.rawURL?.absoluteString ?? "灵感"
    }
}

/// Once a day, a quiet strip at the bottom of the window when old thoughts
/// are waiting. Dismissing it hides it until tomorrow.
enum InspirationReviewNudge {
    static let dismissedDayKey = "inspiration.review.nudgeDismissedDay.v1"

    static func dayKey(_ now: Date, timeZone: TimeZone = .current) -> String {
        let day = CalendarDate.today(in: timeZone, now: now)
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func shouldShow(dueCount: Int, now: Date, defaults: UserDefaults = .standard) -> Bool {
        dueCount > 0 && defaults.string(forKey: dismissedDayKey) != dayKey(now)
    }

    static func dismiss(now: Date, defaults: UserDefaults = .standard) {
        defaults.set(dayKey(now), forKey: dismissedDayKey)
    }
}

struct InspirationReviewNudgeView: View {
    let dueCount: Int
    let onStart: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
                .foregroundStyle(theme.controlAccent)
            Text("\(dueCount) 条旧灵感等你回顾")
            Button("开始", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("今天不看", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspiration-review-nudge")
    }
}
