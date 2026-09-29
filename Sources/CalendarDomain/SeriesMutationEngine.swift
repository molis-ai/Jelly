import Foundation

public struct RecurrenceGraph: Codable, Equatable, Sendable {
    public var series: [UUID: WeeklySeries]
    public var exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    public var completions: [OccurrenceKey: OccurrenceCompletion]

    public init(
        series: [UUID: WeeklySeries],
        exceptions: [OccurrenceKey: OccurrenceExceptionKind],
        completions: [OccurrenceKey: OccurrenceCompletion]
    ) {
        self.series = series
        self.exceptions = exceptions
        self.completions = completions
    }
}

public enum SeriesScope: Equatable, Sendable {
    case onlyThis
    case thisAndFuture
}

public enum SeriesFutureMutationOutcome: Equatable, Sendable {
    case split(
        oldSeriesID: UUID,
        newSeriesID: UUID,
        boundary: CalendarDate,
        dayDelta: Int,
        historicalOwnerRetained: Bool
    )
    case deleteFuture(
        seriesID: UUID,
        boundary: CalendarDate,
        historicalOwnerRetained: Bool
    )
}

public struct SeriesMutationResult: Equatable, Sendable {
    public let graph: RecurrenceGraph
    public let futureOutcome: SeriesFutureMutationOutcome?

    public init(graph: RecurrenceGraph, futureOutcome: SeriesFutureMutationOutcome?) {
        self.graph = graph
        self.futureOutcome = futureOutcome
    }
}

public enum OptionalPatch<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)
    case clear
}

public struct SeriesPatch: Sendable {
    public var title: String?
    public var kind: ItemKind?
    public var categoryID: UUID?
    public var weekdays: Set<Weekday>?
    public var recurrenceEndDate: OptionalPatch<CalendarDate>
    public var displayedStartDate: CalendarDate?
    public var durationDays: Int?
    public var startTime: OptionalPatch<MinuteOfDay>
    public var endTime: OptionalPatch<MinuteOfDay>
    public var priority: ItemPriority?
    public var isPinned: Bool?
    /// nil = leave notes unchanged; non-nil (including "") replaces notes.
    public var notes: String?
    /// Series-level only: an only-this edit that changes it is rejected.
    public var reminder: OptionalPatch<ItemReminder>

    public init(
        title: String? = nil,
        kind: ItemKind? = nil,
        categoryID: UUID? = nil,
        weekdays: Set<Weekday>? = nil,
        recurrenceEndDate: OptionalPatch<CalendarDate> = .unchanged,
        displayedStartDate: CalendarDate? = nil,
        durationDays: Int? = nil,
        startTime: OptionalPatch<MinuteOfDay> = .unchanged,
        endTime: OptionalPatch<MinuteOfDay> = .unchanged,
        priority: ItemPriority? = nil,
        isPinned: Bool? = nil,
        notes: String? = nil,
        reminder: OptionalPatch<ItemReminder> = .unchanged
    ) {
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.weekdays = weekdays
        self.recurrenceEndDate = recurrenceEndDate
        self.displayedStartDate = displayedStartDate
        self.durationDays = durationDays
        self.startTime = startTime
        self.endTime = endTime
        self.priority = priority
        self.isPinned = isPinned
        self.notes = notes
        self.reminder = reminder
    }
}

public enum SeriesEdit: Sendable {
    case patch(SeriesPatch)
    case delete
}

public enum SeriesMutationError: Error, Equatable, Sendable {
    case unknownSeries
    case unknownOccurrence
    case invalidOnlyThisRulePatch
    case duplicateSeriesID
}

public enum SeriesMutationEngine {
    public static func apply(
        edit: SeriesEdit,
        to key: OccurrenceKey,
        scope: SeriesScope,
        in graph: RecurrenceGraph,
        newSeriesID: UUID,
        now: Date
    ) throws -> RecurrenceGraph {
        try applyWithOutcome(
            edit: edit,
            to: key,
            scope: scope,
            in: graph,
            newSeriesID: newSeriesID,
            now: now
        ).graph
    }

    public static func applyWithOutcome(
        edit: SeriesEdit,
        to key: OccurrenceKey,
        scope: SeriesScope,
        in graph: RecurrenceGraph,
        newSeriesID: UUID,
        now: Date
    ) throws -> SeriesMutationResult {
        guard let series = graph.series[key.seriesID] else {
            throw SeriesMutationError.unknownSeries
        }
        guard identifiesInstance(key, of: series, exceptions: graph.exceptions) else {
            throw SeriesMutationError.unknownOccurrence
        }

        switch scope {
        case .onlyThis:
            return .init(
                graph: try applyOnlyThis(edit: edit, to: key, series: series, graph: graph),
                futureOutcome: nil
            )
        case .thisAndFuture:
            switch edit {
            case .delete:
                let future = applyFutureDelete(to: key, series: series, graph: graph, now: now)
                return .init(
                    graph: future.graph,
                    futureOutcome: .deleteFuture(
                        seriesID: series.id,
                        boundary: key.originalDate,
                        historicalOwnerRetained: future.historicalOwnerRetained
                    )
                )
            case let .patch(patch):
                guard newSeriesID != series.id, graph.series[newSeriesID] == nil else {
                    throw SeriesMutationError.duplicateSeriesID
                }
                let future = try applyFuturePatch(
                    patch,
                    to: key,
                    series: series,
                    graph: graph,
                    newSeriesID: newSeriesID,
                    now: now
                )
                return .init(
                    graph: future.graph,
                    futureOutcome: .split(
                        oldSeriesID: series.id,
                        newSeriesID: newSeriesID,
                        boundary: key.originalDate,
                        dayDelta: future.dayDelta,
                        historicalOwnerRetained: future.historicalOwnerRetained
                    )
                )
            }
        }
    }

    private static func applyOnlyThis(
        edit: SeriesEdit,
        to key: OccurrenceKey,
        series: WeeklySeries,
        graph: RecurrenceGraph
    ) throws -> RecurrenceGraph {
        var result = graph

        switch edit {
        case .delete:
            result.exceptions[key] = .skipped
            result.completions.removeValue(forKey: key)
            return result
        case let .patch(patch):
            guard patch.weekdays == nil,
                  isUnchanged(patch.recurrenceEndDate),
                  isUnchanged(patch.reminder)
            else {
                throw SeriesMutationError.invalidOnlyThisRulePatch
            }

            var override = effectiveOverride(for: key, in: series, exceptions: graph.exceptions)
            try applyOccurrencePatch(patch, to: &override)
            result.exceptions[key] = .modified(override)
            // Unified TODO: keep completion when editing an instance (including legacy event kind).
            return result
        }
    }

    private static func applyFutureDelete(
        to key: OccurrenceKey,
        series: WeeklySeries,
        graph: RecurrenceGraph,
        now: Date
    ) -> (graph: RecurrenceGraph, historicalOwnerRetained: Bool) {
        var result = graph
        removeFutureState(for: series.id, from: key.originalDate, in: &result)
        let historicalOwnerRetained = closeOrRemoveHistoricalSeries(
            series,
            at: key.originalDate,
            graph: graph,
            result: &result,
            now: now
        )
        return (result, historicalOwnerRetained)
    }

    private static func applyFuturePatch(
        _ patch: SeriesPatch,
        to key: OccurrenceKey,
        series: WeeklySeries,
        graph: RecurrenceGraph,
        newSeriesID: UUID,
        now: Date
    ) throws -> (graph: RecurrenceGraph, historicalOwnerRetained: Bool, dayDelta: Int) {
        let dayDelta = patch.displayedStartDate.map { key.originalDate.days(until: $0) } ?? 0
        let future = try makeFutureSeries(
            from: series,
            patch: patch,
            boundary: key.originalDate,
            dayDelta: dayDelta,
            id: newSeriesID,
            now: now
        )

        var result = graph
        removeFutureState(for: series.id, from: key.originalDate, in: &result)
        let historicalOwnerRetained = closeOrRemoveHistoricalSeries(
            series,
            at: key.originalDate,
            graph: graph,
            result: &result,
            now: now
        )
        result.series[future.id] = future

        try migrateFutureExceptions(
            from: series.id,
            boundary: key.originalDate,
            to: future,
            dayDelta: dayDelta,
            boundaryPatch: patch,
            graph: graph,
            result: &result
        )
        migrateFutureCompletions(
            from: series.id,
            boundary: key.originalDate,
            to: future,
            dayDelta: dayDelta,
            graph: graph,
            result: &result
        )
        return (result, historicalOwnerRetained, dayDelta)
    }

    private static func makeFutureSeries(
        from series: WeeklySeries,
        patch: SeriesPatch,
        boundary: CalendarDate,
        dayDelta: Int,
        id: UUID,
        now: Date
    ) throws -> WeeklySeries {
        let weekdays: Set<Weekday>
        if let explicitWeekdays = patch.weekdays {
            weekdays = explicitWeekdays
        } else if dayDelta != 0 {
            weekdays = Set(series.weekdays.map { shiftedWeekday($0, by: dayDelta) })
        } else {
            weekdays = series.weekdays
        }

        let shiftedEndDate = dayDelta == 0
            ? series.recurrenceEndDate
            : series.recurrenceEndDate?.addingDays(dayDelta)
        let recurrenceEndDate: CalendarDate?
        switch patch.recurrenceEndDate {
        case .unchanged:
            recurrenceEndDate = shiftedEndDate
        case let .set(value):
            recurrenceEndDate = value
        case .clear:
            recurrenceEndDate = nil
        }

        var priority = patch.priority ?? series.priority
        let isPinned = patch.isPinned ?? series.isPinned
        if isPinned, priority == .none {
            priority = .p0
        }
        return try WeeklySeries(
            id: id,
            kind: patch.kind ?? series.kind,
            title: patch.title ?? series.title,
            categoryID: patch.categoryID ?? series.categoryID,
            ruleStartDate: boundary.addingDays(dayDelta),
            recurrenceEndDate: recurrenceEndDate,
            weekdays: weekdays,
            durationDays: patch.durationDays ?? series.durationDays,
            startTime: applying(patch.startTime, to: series.startTime),
            endTime: applying(patch.endTime, to: series.endTime),
            priority: priority,
            isPinned: isPinned,
            notes: patch.notes ?? series.notes,
            reminder: applying(patch.reminder, to: series.reminder),
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func closeOrRemoveHistoricalSeries(
        _ series: WeeklySeries,
        at boundary: CalendarDate,
        graph: RecurrenceGraph,
        result: inout RecurrenceGraph,
        now: Date
    ) -> Bool {
        guard hasHistoricalInstanceOrException(
            of: series,
            before: boundary,
            exceptions: graph.exceptions
        ) else {
            result.series.removeValue(forKey: series.id)
            return false
        }

        var historical = series
        let requestedEnd = boundary.previousDay
        if let existingEnd = series.recurrenceEndDate, existingEnd < requestedEnd {
            historical.recurrenceEndDate = existingEnd
        } else {
            historical.recurrenceEndDate = requestedEnd
        }
        historical.updatedAt = now
        result.series[series.id] = historical
        return true
    }

    private static func migrateFutureExceptions(
        from oldSeriesID: UUID,
        boundary: CalendarDate,
        to future: WeeklySeries,
        dayDelta: Int,
        boundaryPatch: SeriesPatch,
        graph: RecurrenceGraph,
        result: inout RecurrenceGraph
    ) throws {
        for (oldKey, exception) in graph.exceptions where isFutureKey(
            oldKey,
            seriesID: oldSeriesID,
            boundary: boundary
        ) {
            let newKey = OccurrenceKey(
                seriesID: future.id,
                originalDate: oldKey.originalDate.addingDays(dayDelta)
            )
            guard isWithinBounds(newKey.originalDate, of: future) else {
                continue
            }

            var migrated = try shifted(exception, by: dayDelta)
            if oldKey.originalDate == boundary,
               case var .modified(override) = migrated {
                try applyOccurrencePatch(boundaryPatch, to: &override)
                migrated = .modified(override)
            }
            result.exceptions[newKey] = migrated
        }
    }

    private static func migrateFutureCompletions(
        from oldSeriesID: UUID,
        boundary: CalendarDate,
        to future: WeeklySeries,
        dayDelta: Int,
        graph: RecurrenceGraph,
        result: inout RecurrenceGraph
    ) {
        for (oldKey, completion) in graph.completions where isFutureKey(
            oldKey,
            seriesID: oldSeriesID,
            boundary: boundary
        ) {
            let newKey = OccurrenceKey(
                seriesID: future.id,
                originalDate: oldKey.originalDate.addingDays(dayDelta)
            )
            guard isWithinBounds(newKey.originalDate, of: future),
                  hasCompletableInstance(newKey, in: future, exceptions: result.exceptions)
            else {
                continue
            }
            result.completions[newKey] = OccurrenceCompletion(
                key: newKey,
                completedAt: completion.completedAt
            )
        }
    }

    private static func removeFutureState(
        for seriesID: UUID,
        from boundary: CalendarDate,
        in graph: inout RecurrenceGraph
    ) {
        graph.exceptions = graph.exceptions.filter { key, _ in
            !isFutureKey(key, seriesID: seriesID, boundary: boundary)
        }
        graph.completions = graph.completions.filter { key, _ in
            !isFutureKey(key, seriesID: seriesID, boundary: boundary)
        }
    }

    private static func identifiesInstance(
        _ key: OccurrenceKey,
        of series: WeeklySeries,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    ) -> Bool {
        guard isWithinBounds(key.originalDate, of: series) else {
            return false
        }
        if case .modified = exceptions[key] {
            return true
        }
        if case .skipped = exceptions[key] {
            return false
        }
        return isNaturallyGenerated(key.originalDate, by: series)
    }

    private static func hasHistoricalInstanceOrException(
        of series: WeeklySeries,
        before boundary: CalendarDate,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    ) -> Bool {
        let historicalEnd: CalendarDate
        if let endDate = series.recurrenceEndDate, endDate < boundary {
            historicalEnd = endDate
        } else {
            historicalEnd = boundary.previousDay
        }
        guard series.ruleStartDate <= historicalEnd else {
            return false
        }

        var date = series.ruleStartDate
        while date <= historicalEnd {
            if identifiesInstance(
                OccurrenceKey(seriesID: series.id, originalDate: date),
                of: series,
                exceptions: exceptions
            ) {
                return true
            }
            date = date.addingDays(1)
        }
        return false
    }

    private static func hasCompletableInstance(
        _ key: OccurrenceKey,
        in series: WeeklySeries,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    ) -> Bool {
        switch exceptions[key] {
        case .skipped:
            return false
        case .modified:
            // Unified TODO: any concrete modified instance can carry completion.
            return true
        case nil:
            return isNaturallyGenerated(key.originalDate, by: series)
        }
    }

    private static func isNaturallyGenerated(
        _ date: CalendarDate,
        by series: WeeklySeries
    ) -> Bool {
        guard date >= series.ruleStartDate,
              series.recurrenceEndDate.map({ date <= $0 }) ?? true
        else {
            return false
        }
        return series.weekdays.contains(date.weekday)
    }

    private static func isWithinBounds(_ date: CalendarDate, of series: WeeklySeries) -> Bool {
        date >= series.ruleStartDate && (series.recurrenceEndDate.map { date <= $0 } ?? true)
    }

    private static func isFutureKey(
        _ key: OccurrenceKey,
        seriesID: UUID,
        boundary: CalendarDate
    ) -> Bool {
        key.seriesID == seriesID && key.originalDate >= boundary
    }

    private static func effectiveOverride(
        for key: OccurrenceKey,
        in series: WeeklySeries,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    ) -> OccurrenceOverride {
        if case let .modified(override) = exceptions[key] {
            return override
        }
        return OccurrenceOverride(
            displayedSchedule: try! CalendarSchedule(
                startDate: key.originalDate,
                endDate: key.originalDate.addingDays(series.durationDays - 1),
                startTime: series.startTime,
                endTime: series.endTime
            ),
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            priority: series.priority,
            isPinned: series.isPinned,
            notes: series.notes
        )
    }

    private static func applyOccurrencePatch(
        _ patch: SeriesPatch,
        to override: inout OccurrenceOverride
    ) throws {
        applyContentPatch(patch, to: &override)
        override.displayedSchedule = try applying(patch, to: override.displayedSchedule)
    }

    private static func applyContentPatch(_ patch: SeriesPatch, to override: inout OccurrenceOverride) {
        if let title = patch.title {
            override.title = title
        }
        if let kind = patch.kind {
            override.kind = kind
        }
        if let categoryID = patch.categoryID {
            override.categoryID = categoryID
        }
        if let priority = patch.priority {
            override.priority = priority
        }
        if let isPinned = patch.isPinned {
            override.isPinned = isPinned
            if isPinned, override.priority == .none {
                override.priority = .p0
            }
        }
        if let notes = patch.notes {
            override.notes = notes
        }
    }

    private static func applying<Value>(
        _ patch: OptionalPatch<Value>,
        to current: Value?
    ) -> Value? where Value: Sendable {
        switch patch {
        case .unchanged:
            current
        case let .set(value):
            value
        case .clear:
            nil
        }
    }

    private static func applying(
        _ patch: SeriesPatch,
        to schedule: CalendarSchedule
    ) throws -> CalendarSchedule {
        let startDate = patch.displayedStartDate ?? schedule.startDate
        let durationDays = patch.durationDays ?? schedule.durationDays
        return try CalendarSchedule(
            startDate: startDate,
            endDate: startDate.addingDays(durationDays - 1),
            startTime: applying(patch.startTime, to: schedule.startTime),
            endTime: applying(patch.endTime, to: schedule.endTime)
        )
    }

    private static func isUnchanged<Value>(_ patch: OptionalPatch<Value>) -> Bool where Value: Sendable {
        if case .unchanged = patch {
            return true
        }
        return false
    }

    private static func shifted(
        _ exception: OccurrenceExceptionKind,
        by dayDelta: Int
    ) throws -> OccurrenceExceptionKind {
        guard dayDelta != 0, case var .modified(override) = exception else {
            return exception
        }
        override.displayedSchedule = try override.displayedSchedule.shifted(byDays: dayDelta)
        return .modified(override)
    }

    private static func shiftedWeekday(_ weekday: Weekday, by dayDelta: Int) -> Weekday {
        let shiftedZeroBased = (weekday.rawValue - 1 + dayDelta) % Weekday.allCases.count
        let normalized = shiftedZeroBased >= 0 ? shiftedZeroBased : shiftedZeroBased + Weekday.allCases.count
        return Weekday(rawValue: normalized + 1)!
    }
}
