import CalendarDomain
import Combine
import Foundation

enum ItemEditorMode: Equatable {
    case create
    case editItem(CalendarItem)
    case editOccurrence(
        series: WeeklySeries,
        key: OccurrenceKey,
        scope: SeriesScope
    )
}

enum ItemEditorError: Error, Equatable {
    case emptyTitle
    case invalidDateRange
    case invalidTimeRange
    case emptyWeekdays
    case invalidRecurrenceEnd
    case noOccurrenceInRange
    case invalidEditorMode
}

@MainActor
final class ItemEditorViewModel: ObservableObject {
    let mode: ItemEditorMode
    private let originalDraft: ItemDraft
    @Published var draft: ItemDraft
    @Published private(set) var validationMessage: String?

    init(mode: ItemEditorMode, draft: ItemDraft) {
        self.mode = mode
        originalDraft = draft
        self.draft = draft
        validationMessage = nil
    }

    /// Keep a valid same-day pair when enabling times (supports 00:00 start).
    func usesTimeDidChange() {
        draft.kind = .unifiedTODO
        guard draft.usesTime else { return }
        normalizeTimedDraftIfNeeded()
    }

    /// User set a start clock: default the block to one hour.
    func startTimeDidChange() {
        guard draft.usesTime else { return }
        applyDefaultEndOneHourAfterStart()
    }

    private func normalizeTimedDraftIfNeeded() {
        if draft.startDate == draft.endDate, draft.endTime <= draft.startTime {
            applyDefaultEndOneHourAfterStart()
        }
    }

    private func applyDefaultEndOneHourAfterStart() {
        let next = draft.startTime.value + 60
        if next < 24 * 60 {
            draft.endDate = draft.startDate
            draft.endTime = MinuteOfDay(hour: next / 60, minute: next % 60)!
        } else {
            let wrapped = next - 24 * 60
            draft.endDate = draft.startDate.addingDays(1)
            draft.endTime = MinuteOfDay(hour: wrapped / 60, minute: wrapped % 60)!
        }
    }

    func makeCommand(
        now: Date,
        newItemID: UUID,
        newSeriesID: UUID,
        timeZoneIdentifier: String
    ) throws -> CalendarCommand {
        do {
            let normalizedTitle = try validatedTitle()
            let schedule = try validatedSchedule()
            // Product model: one completable TODO kind; timed vs untimed is the only split.
            let kind = ItemKind.unifiedTODO

            switch mode {
            case .create:
                if draft.repeatsWeekly {
                    try validateWeeklyRule(
                        starting: schedule.startDate,
                        weekdays: draft.weekdays,
                        recurrenceEndDate: draft.recurrenceEndDate
                    )
                    return .createSeries(try WeeklySeries(
                        id: newSeriesID,
                        kind: kind,
                        title: normalizedTitle,
                        categoryID: draft.categoryID,
                        ruleStartDate: schedule.startDate,
                        recurrenceEndDate: draft.recurrenceEndDate,
                        weekdays: draft.weekdays,
                        durationDays: schedule.durationDays,
                        startTime: schedule.startTime,
                        endTime: schedule.endTime,
                        priority: draft.priority,
                        isPinned: draft.isPinned,
                        notes: draft.notes,
                        creationTimeZoneIdentifier: timeZoneIdentifier,
                        createdAt: now,
                        updatedAt: now
                    ))
                }
                return .createItem(try CalendarItem(
                    id: newItemID,
                    kind: kind,
                    title: normalizedTitle,
                    categoryID: draft.categoryID,
                    schedule: schedule,
                    creationTimeZoneIdentifier: timeZoneIdentifier,
                    priority: draft.priority,
                    isPinned: draft.isPinned,
                    notes: draft.notes,
                    reminder: draft.reminder?.adapted(to: schedule),
                    completedAt: nil,
                    createdAt: now,
                    updatedAt: now
                ))

            case let .editItem(original):
                guard !draft.repeatsWeekly else {
                    throw ItemEditorError.invalidEditorMode
                }
                return .updateItem(try CalendarItem(
                    id: original.id,
                    kind: kind,
                    title: normalizedTitle,
                    categoryID: draft.categoryID,
                    schedule: schedule,
                    creationTimeZoneIdentifier: original.creationTimeZoneIdentifier,
                    priority: draft.priority,
                    isPinned: draft.isPinned,
                    notes: draft.notes,
                    reminder: draft.reminder?.adapted(to: schedule),
                    completedAt: original.completedAt,
                    createdAt: original.createdAt,
                    updatedAt: now
                ))

            case let .editOccurrence(series, key, scope):
                let patch = try makePatch(
                    normalizedTitle: normalizedTitle,
                    schedule: schedule,
                    scope: scope
                )
                if scope == .thisAndFuture {
                    try validateFutureRule(series: series, key: key, patch: patch)
                }
                return .mutateSeries(
                    key,
                    scope: scope,
                    edit: .patch(patch),
                    newSeriesID: newSeriesID
                )
            }
        } catch let error as ItemEditorError {
            validationMessage = error.message
            throw error
        } catch let error as DomainValidationError {
            let editorError = ItemEditorError(domainError: error)
            validationMessage = editorError.message
            throw editorError
        } catch {
            validationMessage = ItemEditorError.invalidEditorMode.message
            throw ItemEditorError.invalidEditorMode
        }
    }

    func makeDeleteCommand(newSeriesID: UUID) throws -> CalendarCommand {
        validationMessage = nil
        switch mode {
        case .create:
            validationMessage = ItemEditorError.invalidEditorMode.message
            throw ItemEditorError.invalidEditorMode
        case let .editItem(item):
            return .deleteItem(item.id)
        case let .editOccurrence(_, key, scope):
            return .mutateSeries(key, scope: scope, edit: .delete, newSeriesID: newSeriesID)
        }
    }

    private func validatedTitle() throws -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ItemEditorError.emptyTitle
        }
        return title
    }

    private func validatedSchedule() throws -> CalendarSchedule {
        do {
            return try CalendarSchedule(
                startDate: draft.startDate,
                endDate: draft.endDate,
                startTime: draft.usesTime ? draft.startTime : nil,
                endTime: draft.usesTime ? draft.endTime : nil
            )
        } catch let error as DomainValidationError {
            throw ItemEditorError(domainError: error)
        }
    }

    private func validateWeeklyRule(
        starting start: CalendarDate,
        weekdays: Set<Weekday>,
        recurrenceEndDate: CalendarDate?
    ) throws {
        guard !weekdays.isEmpty else {
            throw ItemEditorError.emptyWeekdays
        }
        guard let end = recurrenceEndDate else {
            return
        }
        guard end >= start else {
            throw ItemEditorError.invalidRecurrenceEnd
        }
        var candidate = start
        while candidate <= end {
            if weekdays.contains(candidate.weekday) {
                return
            }
            candidate = candidate.addingDays(1)
        }
        throw ItemEditorError.noOccurrenceInRange
    }

    private func validateFutureRule(
        series: WeeklySeries,
        key: OccurrenceKey,
        patch: SeriesPatch
    ) throws {
        let dayDelta = patch.displayedStartDate.map {
            key.originalDate.days(until: $0)
        } ?? 0
        let effectiveStart = key.originalDate.addingDays(dayDelta)
        let effectiveWeekdays: Set<Weekday>
        if let explicitWeekdays = patch.weekdays {
            effectiveWeekdays = explicitWeekdays
        } else if dayDelta != 0 {
            effectiveWeekdays = Set(series.weekdays.map { shiftedWeekday($0, by: dayDelta) })
        } else {
            effectiveWeekdays = series.weekdays
        }

        let shiftedDeadline = dayDelta == 0
            ? series.recurrenceEndDate
            : series.recurrenceEndDate?.addingDays(dayDelta)
        let effectiveDeadline: CalendarDate?
        switch patch.recurrenceEndDate {
        case .unchanged:
            effectiveDeadline = shiftedDeadline
        case let .set(end):
            effectiveDeadline = end
        case .clear:
            effectiveDeadline = nil
        }

        try validateWeeklyRule(
            starting: effectiveStart,
            weekdays: effectiveWeekdays,
            recurrenceEndDate: effectiveDeadline
        )
    }

    private func makePatch(
        normalizedTitle: String,
        schedule: CalendarSchedule,
        scope: SeriesScope
    ) throws -> SeriesPatch {
        let originalTitle = originalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSchedule = try CalendarSchedule(
            startDate: originalDraft.startDate,
            endDate: originalDraft.endDate,
            startTime: originalDraft.usesTime ? originalDraft.startTime : nil,
            endTime: originalDraft.usesTime ? originalDraft.endTime : nil
        )
        let (startTime, endTime) = pairedTimePatch(
            schedule: schedule,
            originalSchedule: originalSchedule
        )

        var recurrenceEndDate: OptionalPatch<CalendarDate> = .unchanged
        if scope == .thisAndFuture {
            switch (originalDraft.recurrenceEndDate, draft.recurrenceEndDate) {
            case (nil, nil):
                recurrenceEndDate = .unchanged
            case let (.some(old), .some(new)) where old == new:
                recurrenceEndDate = .unchanged
            case (_, .none):
                recurrenceEndDate = .clear
            case let (_, .some(end)):
                recurrenceEndDate = .set(end)
            }
        }

        return SeriesPatch(
            title: normalizedTitle == originalTitle ? nil : normalizedTitle,
            kind: draft.kind == originalDraft.kind ? nil : draft.kind,
            categoryID: draft.categoryID == originalDraft.categoryID ? nil : draft.categoryID,
            weekdays: scope == .thisAndFuture && draft.weekdays != originalDraft.weekdays
                ? draft.weekdays
                : nil,
            recurrenceEndDate: recurrenceEndDate,
            displayedStartDate: schedule.startDate == originalSchedule.startDate
                ? nil
                : schedule.startDate,
            durationDays: schedule.durationDays == originalSchedule.durationDays
                ? nil
                : schedule.durationDays,
            startTime: startTime,
            endTime: endTime,
            priority: draft.priority == originalDraft.priority ? nil : draft.priority,
            isPinned: draft.isPinned == originalDraft.isPinned ? nil : draft.isPinned,
            notes: draft.notes == originalDraft.notes ? nil : draft.notes
        )
    }

    private func pairedTimePatch(
        schedule: CalendarSchedule,
        originalSchedule: CalendarSchedule
    ) -> (OptionalPatch<MinuteOfDay>, OptionalPatch<MinuteOfDay>) {
        switch (schedule.startTime, schedule.endTime, originalSchedule.startTime, originalSchedule.endTime) {
        case let (.some(start), .some(end), .some(originalStart), .some(originalEnd))
            where start == originalStart && end == originalEnd:
            return (.unchanged, .unchanged)
        case let (.some(start), .some(end), _, _):
            return (.set(start), .set(end))
        case (nil, nil, nil, nil):
            return (.unchanged, .unchanged)
        case (nil, nil, _, _):
            return (.clear, .clear)
        default:
            preconditionFailure("CalendarSchedule always has paired times.")
        }
    }

    private func shiftedWeekday(_ weekday: Weekday, by dayDelta: Int) -> Weekday {
        let shiftedZeroBased = (weekday.rawValue - 1 + dayDelta) % Weekday.allCases.count
        let normalized = shiftedZeroBased >= 0
            ? shiftedZeroBased
            : shiftedZeroBased + Weekday.allCases.count
        return Weekday(rawValue: normalized + 1)!
    }
}

extension ItemEditorError {
    fileprivate init(domainError: DomainValidationError) {
        switch domainError {
        case .emptyTitle: self = .emptyTitle
        case .invalidDateRange: self = .invalidDateRange
        case .invalidTimeRange: self = .invalidTimeRange
        case .emptyWeekdaySet: self = .emptyWeekdays
        case .invalidRecurrenceEnd: self = .invalidRecurrenceEnd
        case .noOccurrenceInRange: self = .noOccurrenceInRange
        case .eventCannotComplete, .invalidTimeZoneIdentifier: self = .invalidEditorMode
        }
    }

    var message: String {
        switch self {
        case .emptyTitle: "请填写标题"
        case .invalidDateRange: "结束日期不能早于开始日期"
        case .invalidTimeRange: "结束时间必须晚于开始时间"
        case .emptyWeekdays: "请至少选择一个重复日"
        case .invalidRecurrenceEnd: "重复结束日期不能早于开始日期"
        case .noOccurrenceInRange: "重复范围内至少需要包含一次"
        case .invalidEditorMode: "当前事项不能这样编辑"
        }
    }
}
