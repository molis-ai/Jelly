import CalendarDomain
import Foundation
import WorkspaceDomain

struct MobileItemEditorRequest: Identifiable {
    let id = UUID()
    let mode: ItemEditorMode
    let draft: ItemDraft

    static func existing(_ entry: ProjectedEntry, scope: SeriesScope, state: WorkspaceState) throws -> Self {
        let mode: ItemEditorMode
        switch entry {
        case let .item(item): mode = .editItem(item)
        case let .occurrence(value):
            guard let series = state.calendar.recurrence.series[value.key.seriesID] else { throw MobileItemEditingError.missing }
            mode = .editOccurrence(series: series, key: value.key, scope: scope)
        }
        return try MobileItemEditing.current(mode: mode, state: state)
    }
}

enum MobileItemEditingError: LocalizedError {
    case missing
    case conflict(String)
    case notesMoved

    var errorDescription: String? {
        switch self {
        case .missing: "这个事项已被删除或不再属于原来的重复规则。输入已保留，请返回日历核对。"
        case let .conflict(field): "\(field)已在其他位置修改。为避免覆盖，本次没有保存，输入已保留；请复制需要的内容，再重新打开事项。"
        case .notesMoved: "随记已迁入主笔记，但这里还有未保存的随记修改。请先复制到主笔记，或选择使用主笔记中的内容。"
        }
    }
}

/// Rebase editor changes on the currently published workspace. Completion and
/// other untouched fields must come from that state, not the sheet's snapshot.
enum MobileItemEditing {
    static func current(mode: ItemEditorMode, state: WorkspaceState) throws -> MobileItemEditorRequest {
        switch mode {
        case .create: throw MobileItemEditingError.missing
        case let .editItem(original):
            guard let item = state.calendar.items[original.id] else { throw MobileItemEditingError.missing }
            return .init(mode: .editItem(item), draft: .init(item: item))
        case let .editOccurrence(_, key, scope):
            let graph = state.calendar.recurrence
            guard let series = graph.series[key.seriesID] else { throw MobileItemEditingError.missing }
            let start: CalendarDate
            let end: CalendarDate
            if case let .modified(override) = graph.exceptions[key] {
                start = override.displayedSchedule.startDate
                end = override.displayedSchedule.endDate
            } else {
                start = key.originalDate
                end = start.addingDays(series.durationDays - 1)
            }
            guard let occurrence = RecurrenceEngine.occurrences(of: series, in: .init(start: start, end: end),
                exceptions: graph.exceptions, completions: graph.completions).first(where: { $0.key == key }) else {
                throw MobileItemEditingError.missing
            }
            return .init(mode: .editOccurrence(series: series, key: key, scope: scope), draft: .init(occurrence: occurrence, series: series))
        }
    }

    /// All calendar completion surfaces use current persisted state. The raw
    /// calendar completion command supports ordinary items and the workspace
    /// reducer also synchronizes any linked task block in the same transaction.
    static func completionCommand(for target: ProjectedEntryID, state: WorkspaceState, now: Date = Date()) throws -> WorkspaceCommand {
        switch target {
        case let .item(id):
            guard let item = state.calendar.items[id] else { throw MobileItemEditingError.missing }
            return .calendar(.setTaskCompleted(id, item.completedAt == nil ? now : nil))
        case let .occurrence(key):
            guard let series = state.calendar.recurrence.series[key.seriesID] else { throw MobileItemEditingError.missing }
            _ = try current(mode: .editOccurrence(series: series, key: key, scope: .onlyThis), state: state)
            return .calendar(.setOccurrenceCompleted(key, state.calendar.recurrence.completions[key] == nil ? now : nil))
        }
    }

    static func completionCommand(mode: ItemEditorMode, state: WorkspaceState, now: Date = Date()) throws -> WorkspaceCommand {
        let target: ProjectedEntryID
        switch mode {
        case .create: throw MobileItemEditingError.missing
        case let .editItem(item): target = .item(item.id)
        case let .editOccurrence(_, key, _): target = .occurrence(key)
        }
        return try completionCommand(for: target, state: state, now: now)
    }

    static func hasPrimaryNote(mode: ItemEditorMode, state: WorkspaceState) -> Bool {
        let target: CalendarTargetID
        switch mode {
        case .create: return false
        case let .editItem(item): target = .item(item.id)
        case let .editOccurrence(_, key, _): target = .occurrence(key)
        }
        return (try? CalendarNoteRelationResolver.resolve(target, calendar: state.calendar,
            relations: state.calendarNoteRelations).noteSet.primaryNoteID) != nil
    }

    @MainActor
    static func command(request: MobileItemEditorRequest, edited: ItemDraft, state: WorkspaceState,
                        now: Date = Date(), newItemID: UUID = UUID(), newSeriesID: UUID = UUID(),
                        timeZoneIdentifier: String = TimeZone.current.identifier) throws -> CalendarCommand {
        let model: ItemEditorViewModel
        if case .create = request.mode {
            model = .init(mode: .create, draft: edited)
        } else {
            let latest = try current(mode: request.mode, state: state)
            let merged = try merge(baseline: request.draft, edited: edited, latest: latest.draft,
                                   hasPrimaryNote: hasPrimaryNote(mode: latest.mode, state: state))
            model = .init(mode: latest.mode, draft: latest.draft)
            model.draft = merged
        }
        let command = try model.makeCommand(now: now, newItemID: newItemID, newSeriesID: newSeriesID,
                                            timeZoneIdentifier: timeZoneIdentifier)
        if case var .updateItem(item) = command {
            // Manual order is outside ItemDraft. Retain the latest rank when
            // the common editor reconstructs a CalendarItem.
            item.untimedRank = state.calendar.items[item.id]?.untimedRank ?? item.untimedRank
            return .updateItem(item)
        }
        return command
    }

    static func merge(baseline: ItemDraft, edited: ItemDraft, latest: ItemDraft, hasPrimaryNote: Bool) throws -> ItemDraft {
        var result = latest
        func field<T: Equatable>(_ key: WritableKeyPath<ItemDraft, T>, _ name: String) throws {
            let old = baseline[keyPath: key], user = edited[keyPath: key], current = latest[keyPath: key]
            guard user != old else { return }
            guard current == old || current == user else { throw MobileItemEditingError.conflict(name) }
            result[keyPath: key] = user
        }
        try field(\.kind, "事项类型")
        try field(\.title, "标题")
        try field(\.categoryID, "分类")
        try field(\.priority, "优先级")
        try field(\.isPinned, "置顶状态")
        try field(\.reminder, "提醒")
        if !sameSchedule(baseline, edited) {
            guard sameSchedule(latest, baseline) || sameSchedule(latest, edited) else { throw MobileItemEditingError.conflict("日期与时间") }
            result.startDate = edited.startDate; result.endDate = edited.endDate
            result.usesTime = edited.usesTime; result.startTime = edited.startTime; result.endTime = edited.endTime
        }
        if !sameRecurrence(baseline, edited) {
            guard sameRecurrence(latest, baseline) || sameRecurrence(latest, edited) else { throw MobileItemEditingError.conflict("重复规则") }
            result.repeatsWeekly = edited.repeatsWeekly; result.weekdays = edited.weekdays
            result.recurrenceEndDate = edited.recurrenceEndDate
        }
        if hasPrimaryNote {
            guard edited.notes == baseline.notes || edited.notes == latest.notes else { throw MobileItemEditingError.notesMoved }
            // Relation migration owns legacy markdown. Never restore it from an
            // editor opened before migration; its actual content is in the note.
            result.notes = latest.notes
        } else { try field(\.notes, "随记") }
        return result
    }

    static func applying(_ schedule: CalendarSchedule, to draft: ItemDraft) -> ItemDraft {
        var result = draft
        result.startDate = schedule.startDate; result.endDate = schedule.endDate
        result.usesTime = schedule.startTime != nil
        if let start = schedule.startTime { result.startTime = start }
        if let end = schedule.endTime { result.endTime = end }
        return result
    }

    private static func sameSchedule(_ a: ItemDraft, _ b: ItemDraft) -> Bool {
        a.startDate == b.startDate && a.endDate == b.endDate && a.usesTime == b.usesTime &&
        (!a.usesTime || (a.startTime == b.startTime && a.endTime == b.endTime))
    }
    private static func sameRecurrence(_ a: ItemDraft, _ b: ItemDraft) -> Bool {
        a.repeatsWeekly == b.repeatsWeekly && a.weekdays == b.weekdays && a.recurrenceEndDate == b.recurrenceEndDate
    }
}
