import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Seeds an isolated data directory for hands-on acceptance of the inventory
/// follow-up (review, expansion, synthesis, undated list, reminders).
///   JELLY_WRITE_ACCEPTANCE_FIXTURE=/tmp/jelly-acceptance/data swift test --filter AcceptanceFixtureWriter
@Suite("AcceptanceFixtureWriter")
struct AcceptanceFixtureWriter {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLY_WRITE_ACCEPTANCE_FIXTURE"] != nil))
    func writeFixture() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JELLY_WRITE_ACCEPTANCE_FIXTURE"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()
        var state = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: now))
        let uncategorized = state.calendar.uncategorizedID
        let work = CalendarCategory(id: UUID(), name: "工作", colorHex: "#A55D3B", sortIndex: 1, createdAt: now, updatedAt: now)
        state.calendar.categories[work.id] = work

        let thoughts = [
            ("周报只写三件事：进展、要别人配合的、我担心的", 9),
            ("给爸妈做一个大字版的日历", 6),
            ("播客可以按问题切成卡片", 4),
            ("换工作前先列出不想再做的事", 2)
        ]
        for (text, days) in thoughts {
            let inspiration = Inspiration.text(rawText: text, categoryID: uncategorized, now: now.addingTimeInterval(-Double(days) * 86_400))
            state.inspirations[inspiration.id] = inspiration
        }
        for title in ["深度工作的三个前提", "为什么计划总是被打断"] {
            var material = Inspiration.text(rawText: "（材料）\(title)", categoryID: uncategorized, now: now.addingTimeInterval(-3 * 86_400))
            material.lastReviewedAt = now
            state.inspirations[material.id] = material
            state.materialDigests[material.id] = try succeededDigest(for: material, now: now)
        }

        let today = CalendarDate.localDay(containing: now, in: .current)
        let meeting = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "周会",
            categoryID: work.id,
            schedule: CalendarSchedule(
                startDate: today.addingDays(1),
                endDate: today.addingDays(1),
                startTime: MinuteOfDay(hour: 10, minute: 0),
                endTime: MinuteOfDay(hour: 11, minute: 0)
            ),
            reminder: .beforeStart(minutes: 10),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        state.calendar.items[meeting.id] = meeting
        if ProcessInfo.processInfo.environment["JELLY_FIXTURE_SOON_REMINDER"] == "1" {
            // Rings a few minutes after the fixture is written.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let soon = now.addingTimeInterval(4 * 60)
            let parts = calendar.dateComponents([.hour, .minute], from: soon)
            let start = MinuteOfDay(hour: parts.hour!, minute: parts.minute!)!
            let end = MinuteOfDay(hour: parts.hour!, minute: min(59, parts.minute! + 30)) ?? start
            let check = try CalendarItem(
                id: UUID(),
                kind: .task,
                title: "Jelly 提醒验收",
                categoryID: uncategorized,
                schedule: CalendarSchedule(
                    startDate: CalendarDate.localDay(containing: soon, in: .current),
                    endDate: CalendarDate.localDay(containing: soon, in: .current),
                    startTime: start,
                    endTime: end > start ? end : MinuteOfDay(hour: min(23, parts.hour! + 1), minute: 0)!
                ),
                notes: "这是 Jelly 提醒功能的验收提醒，验收后会自动移除。",
                reminder: .beforeStart(minutes: 0),
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            state.calendar.items[check.id] = check
        }
        for title in ["学尤克里里", "整理 2025 年的照片"] {
            let item = UndatedItem(title: title, categoryID: uncategorized, createdAt: now, updatedAt: now)
            state.undatedItems[item.id] = item
        }
        try WorkspaceValidator.validate(state)
        try WorkspaceDocumentCodec.encode(state).write(to: root.appendingPathComponent("calendar-v1.json"), options: .atomic)
        print("ACCEPTANCE FIXTURE written to \(root.path)")
    }
}
