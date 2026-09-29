import CalendarDomain
import Foundation
import Observation
import WorkspaceDomain

/// 以后再说：to-dos without a day. Typing a date in the add field skips the
/// list and puts the item straight on the calendar.
@MainActor
@Observable
final class UndatedListModel {
    enum AddOutcome: Equatable {
        case listed
        case scheduled(CalendarDate)
        case rejected
    }

    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    var draft = ""
    private(set) var message: String?

    init(
        store: WorkspaceStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .current
    ) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
    }

    var items: [UndatedItem] {
        store.state.undatedItems.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var count: Int { store.state.undatedItems.count }

    private var today: CalendarDate { CalendarDate.localDay(containing: clock(), in: timeZone) }

    var draftRecognition: String? {
        let parse = QuickAddParser.parse(draft, today: today)
        guard parse.recognizedSchedule else { return nil }
        return QuickAddPresentation.summary(parse, defaultDate: today).map { "会直接放进日历：\($0)" }
    }

    @discardableResult
    func add() async -> AddOutcome {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected }
        let now = clock()
        let parse = QuickAddParser.parse(text, today: today)
        let categoryID = store.calendarState.uncategorizedID
        do {
            if parse.recognizedSchedule {
                let base = ItemDraft.newItem(from: today, through: today, categoryID: categoryID)
                var applied = try base.applying(parse)
                if applied.title.isEmpty { applied.title = text }
                let schedule = try CalendarSchedule(
                    startDate: applied.startDate,
                    endDate: applied.endDate,
                    startTime: applied.usesTime ? applied.startTime : nil,
                    endTime: applied.usesTime ? applied.endTime : nil
                )
                let item = try CalendarItem(
                    id: UUID(),
                    kind: .unifiedTODO,
                    title: applied.title,
                    categoryID: categoryID,
                    schedule: schedule,
                    creationTimeZoneIdentifier: timeZone.identifier,
                    reminder: applied.reminder,
                    completedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )
                let outcome = try await store.sendWorkspace(
                    .calendar(.createItem(item)),
                    undoLabel: WorkspaceCreationFeedback.calendar(
                        title: item.title,
                        date: schedule.startDate,
                        categoryName: store.calendarState.categories[categoryID]?.name ?? "未分类"
                    )
                )
                guard case .committed = outcome else { return fail() }
                draft = ""
                message = nil
                return .scheduled(schedule.startDate)
            }
            let item = UndatedItem(
                title: text,
                categoryID: categoryID,
                createdAt: now,
                updatedAt: now
            )
            let outcome = try await store.sendWorkspace(.createUndatedItem(item), undoLabel: "加入无日期清单")
            guard case .committed = outcome else { return fail() }
            draft = ""
            message = nil
            return .listed
        } catch {
            return fail()
        }
    }

    @discardableResult
    func schedule(_ id: UUID, choice: InspirationScheduleChoice) async -> Bool {
        guard let undated = store.state.undatedItems[id],
              let day = InspirationActionFactory.date(for: choice, today: today)
        else { return false }
        let now = clock()
        do {
            let item = try CalendarItem(
                id: UUID(),
                kind: .unifiedTODO,
                title: undated.title,
                categoryID: undated.categoryID,
                schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
                creationTimeZoneIdentifier: timeZone.identifier,
                priority: undated.priority,
                notes: undated.notes,
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            let outcome = try await store.sendWorkspace(
                .scheduleUndatedItem(id, item: item),
                undoLabel: choice.confirmation
            )
            if case .committed = outcome { return true }
        } catch {}
        message = "没能安排，事项还在清单里。"
        return false
    }

    @discardableResult
    func rename(_ id: UUID, to title: String) async -> Bool {
        guard var item = store.state.undatedItems[id] else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return false }
        item.title = trimmed
        item.updatedAt = clock()
        return (try? await store.sendWorkspace(.updateUndatedItem(item), undoLabel: "修改无日期事项")).map {
            if case .committed = $0 { return true } else { return false }
        } ?? false
    }

    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        guard store.state.undatedItems[id] != nil else { return false }
        return (try? await store.sendWorkspace(.deleteUndatedItem(id), undoLabel: "删除无日期事项")).map {
            if case .committed = $0 { return true } else { return false }
        } ?? false
    }

    private func fail() -> AddOutcome {
        message = "没有保存，输入还在。"
        return .rejected
    }
}
