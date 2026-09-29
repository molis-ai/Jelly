import AppKit
import CalendarDomain
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Renders the new inventory-follow-up surfaces to PNG for visual review.
///   JELLY_RENDER_SNAPSHOTS=/tmp/out swift test --filter InventorySnapshotRenderer
@Suite("InventorySnapshotRenderer")
@MainActor
struct InventorySnapshotRenderer {
    nonisolated static let output = ProcessInfo.processInfo.environment["JELLY_RENDER_SNAPSHOTS"]

    private func render<V: View>(_ name: String, width: CGFloat, _ view: V) throws {
        let directory = URL(fileURLWithPath: Self.output!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let hosted = view
                .environment(\.colorScheme, scheme)
                .frame(width: width)
                .background(CalendarTheme.appearance(for: scheme).canvas)
            let hosting = NSHostingView(rootView: hosted)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let data = rep.representation(using: .png, properties: [:])
            try data?.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func fixtureStore() async throws -> (WorkspaceStore, [InspirationID]) {
        let now = Date()
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: now))
        var ids: [InspirationID] = []
        for (text, days) in [("周报只写三件事：进展、要别人配合的、我担心的", 9), ("给爸妈做一个大字版的日历", 6)] {
            var inspiration = Inspiration.text(rawText: text, categoryID: state.calendar.uncategorizedID, now: now.addingTimeInterval(-Double(days) * 86_400))
            inspiration.expansion = InspirationExpansion(
                supplement: "关键是先找到一个愿意试用的人，再决定做到多完整。",
                directions: [
                    ExpansionDirection(text: "列出三个可能的试用者", decision: .adopted),
                    ExpansionDirection(text: "写一页说明发给其中一个"),
                    ExpansionDirection(text: "先用纸笔画一个样子", decision: .ignored)
                ],
                sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                modelIdentifier: "local/codex",
                createdAt: now
            )
            state.inspirations[inspiration.id] = inspiration
            ids.append(inspiration.id)
        }
        for title in ["深度工作的三个前提", "为什么计划总是被打断"] {
            var material = Inspiration.text(rawText: "（材料）\(title)", categoryID: state.calendar.uncategorizedID, now: now)
            material.lastReviewedAt = now
            if title.hasPrefix("深度") {
                material.perspective = InspirationPerspective(questions: ["你同意吗？"], answer: "部分同意", updatedAt: now)
            }
            state.inspirations[material.id] = material
            state.materialDigests[material.id] = try succeededDigest(for: material, now: now)
        }
        for title in ["学尤克里里", "整理 2025 年的照片"] {
            let item = UndatedItem(title: title, categoryID: state.calendar.uncategorizedID, createdAt: now, updatedAt: now)
            state.undatedItems[item.id] = item
        }
        let store = WorkspaceStore(initialState: state, repository: InMemoryWorkspaceRepository(workspace: state))
        await store.load()
        return (store, ids)
    }

    @Test(.enabled(if: InventorySnapshotRenderer.output != nil))
    func renderSurfaces() async throws {
        let (store, ids) = try await fixtureStore()
        let followUp = InspirationFollowUpService(store: store, model: ScriptedTextModel([]))

        let quick = QuickCaptureModel { _ in }
        quick.text = "地铁上想到：周报可以只写三件事"
        try render("quick-capture", width: 560, QuickCaptureView(model: quick, shortcutTitle: "⌃⌥J", onDone: {}))

        try render("review-sheet", width: 520, InspirationReviewSheet(store: store, onClose: {}))

        let inspiration = try #require(store.state.inspirations[ids[1]])
        try render("expansion", width: 620, InspirationExpansionSection(inspiration: inspiration, followUp: followUp).padding(20))

        let undated = UndatedListModel(store: store)
        undated.draft = "周五下午3点 复盘"
        try render("undated-panel", width: UndatedListPanel.width, UndatedListPanel(model: undated, categories: store.calendarState.categories, onClose: {}).frame(height: 420))

        var reminder: ItemReminder? = .beforeStart(minutes: 10)
        try render("reminder-picker", width: 360, EditorReminderPicker(
            reminder: Binding(get: { reminder }, set: { reminder = $0 }),
            usesTime: true
        ).padding(12))

        try render("nudge", width: 360, InspirationReviewNudgeView(dueCount: 2, onStart: {}, onDismiss: {}).padding(12))

        let suite = "jelly-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reminders = ReminderSyncService(
            store: store,
            gateway: FakeReminderGateway(),
            mappingURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"),
            settings: ReminderSyncSettings(defaults: defaults)
        )
        try render("settings-reminders", width: 560, ReminderSettingsView(service: reminders))
        let sync = WorkspaceSyncService(
            store: store,
            dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            settings: SyncSettings(defaults: defaults),
            deviceName: "Mac"
        )
        try render("settings-sync", width: 560, SyncSettingsView(service: sync))
        try render("settings-quick-capture", width: 560, QuickCaptureSettingsView(coordinator: nil))
        try render("synthesis-sheet", width: 520, MaterialSynthesisSheet(store: store, followUp: followUp, onCreated: { _ in }, onClose: {}))
    }
}
