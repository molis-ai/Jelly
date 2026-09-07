import CalendarDomain
import Foundation
import WorkspaceDomain

/// The MCP tool surface over Jelly's calendar/schedule command layer. Every
/// write goes through `JellyMCPGateway.send`, i.e. the same validated,
/// undoable transaction path the app UI uses.
public struct JellyMCPToolbox: MCPToolHandler {
    public let gateway: any JellyMCPGateway

    public init(gateway: any JellyMCPGateway) {
        self.gateway = gateway
    }

    // MARK: MCPToolHandler

    public func definitions() -> [MCPToolDefinition] {
        MCPToolSchemas.all
    }

    public func call(name: String, arguments: MCPJSON) async -> MCPCallResult {
        do {
            let payload = try await dispatch(name: name, arguments: arguments)
            return .success(payload)
        } catch {
            let detail = Self.describe(error)
            return .failure(.object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string(detail.code),
                    "message": .string(detail.message)
                ])
            ]))
        }
    }

    // MARK: Routing

    private func dispatch(name: String, arguments: MCPJSON) async throws -> MCPJSON {
        switch name {
        case "jelly_list_items":
            return try await listItems(arguments)
        case "jelly_get_item":
            return try await getItem(arguments)
        case "jelly_search":
            return try await search(arguments)
        case "jelly_list_categories":
            return try await listCategories()
        case "jelly_create_item":
            return try await createItem(arguments)
        case "jelly_update_item":
            return try await updateItem(arguments)
        case "jelly_move_items":
            return try await moveItems(arguments)
        case "jelly_set_task_completed":
            return try await setTaskCompleted(arguments)
        case "jelly_delete_item":
            return try await deleteItem(arguments)
        case "jelly_reorder_untimed_items":
            return try await reorderUntimedItems(arguments)
        case "jelly_create_series":
            return try await createSeries(arguments)
        case "jelly_modify_series":
            return try await modifySeries(arguments)
        case "jelly_undo":
            return try await undo()
        default:
            throw MCPGatewayError(code: "unknown_tool", message: "未知工具：\(name)")
        }
    }

    // MARK: Read tools

    private func listItems(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(ListItemsArgs.self)
        let date = try MCPArgParsing.calendarDate(args.date, field: "date")
        let span = MCPArgParsing.listSpan(args.span)
        let state = await gateway.currentState()
        let range = MCPArgParsing.dateRange(for: date, span: span)
        let projection = TimelineProjection.make(
            in: range,
            state: state.calendar,
            hiddenCategoryIDs: []
        )
        let entries = projection.entries.map {
            MCPFormatting.entry($0, categories: state.calendar.categories)
        }
        return .object([
            "ok": .bool(true),
            "date": .string(args.date),
            "span": .string(span.rawValue),
            "range_start": .string(MCPFormatting.date(range.start)),
            "range_end": .string(MCPFormatting.date(range.end)),
            "count": .int(Int64(entries.count)),
            "items": .array(entries)
        ])
    }

    private func getItem(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(GetItemArgs.self)
        let id = try MCPArgParsing.uuid(args.id, field: "id")
        let state = await gateway.currentState()
        guard let item = state.calendar.items[id] else {
            throw MCPGatewayError(code: "not_found", message: "日程条目不存在：\(args.id)")
        }
        return .object([
            "ok": .bool(true),
            "item": MCPFormatting.fullItem(item, categories: state.calendar.categories)
        ])
    }

    private func search(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(SearchArgs.self)
        let kind = try MCPArgParsing.objectKind(args.kind)
        let state = await gateway.currentState()
        let projection = WorkspaceSearchProjection.build(from: state)
        let records = projection.search(
            query: args.query,
            kind: kind,
            includeArchived: args.includeArchived ?? false
        )
        let results = records.prefix(50).map { record in
            MCPFormatting.searchRecord(record, state: state)
        }
        return .object([
            "ok": .bool(true),
            "query": .string(args.query),
            "count": .int(Int64(results.count)),
            "results": .array(results)
        ])
    }

    private func listCategories() async throws -> MCPJSON {
        let state = await gateway.currentState()
        let categories = state.calendar.categories.values
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { category in
                MCPFormatting.category(
                    category,
                    isUncategorized: category.id == state.calendar.uncategorizedID
                )
            }
        return .object([
            "ok": .bool(true),
            "categories": .array(categories)
        ])
    }

    // MARK: Item write tools

    private func createItem(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(CreateItemArgs.self)
        let date = try MCPArgParsing.calendarDate(args.date, field: "date")
        let endDate = try args.endDate.map { try MCPArgParsing.calendarDate($0, field: "end_date") }
        let times = try MCPArgParsing.timePair(start: args.startTime, end: args.endTime)
        let priority = try MCPArgParsing.priority(args.priority) ?? .none
        let state = await gateway.currentState()
        let categoryId = try resolveCategoryID(args.categoryId, in: state)
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: args.title,
            categoryID: categoryId,
            schedule: try CalendarSchedule(
                startDate: date,
                endDate: endDate ?? date,
                startTime: times.start,
                endTime: times.end
            ),
            priority: priority,
            isPinned: args.pinned ?? false,
            notes: args.notes ?? "",
            completedAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let result = try await gateway.send(
            .calendar(.createItem(item)),
            undoLabel: "MCP 创建「\(item.title)」"
        )
        return try committed(result) {
            .object([
                "ok": .bool(true),
                "created": .bool(true),
                "item": MCPFormatting.fullItem(item, categories: state.calendar.categories)
            ])
        }
    }

    private func updateItem(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(UpdateItemArgs.self)
        let id = try MCPArgParsing.uuid(args.id, field: "id")
        let state = await gateway.currentState()
        guard let current = state.calendar.items[id] else {
            throw MCPGatewayError(code: "not_found", message: "日程条目不存在：\(args.id)。改日期请用 jelly_move_items。")
        }

        let startTime: MinuteOfDay?
        let endTime: MinuteOfDay?
        if args.clearTimes == true {
            startTime = nil
            endTime = nil
        } else if args.startTime != nil || args.endTime != nil {
            let pair = try MCPArgParsing.timePair(start: args.startTime, end: args.endTime)
            startTime = pair.start
            endTime = pair.end
        } else {
            startTime = current.schedule.startTime
            endTime = current.schedule.endTime
        }
        let schedule = try CalendarSchedule(
            startDate: current.schedule.startDate,
            endDate: current.schedule.endDate,
            startTime: startTime,
            endTime: endTime
        )
        let priority = try MCPArgParsing.priority(args.priority) ?? current.priority
        let pinned = args.pinned ?? current.isPinned
        let categoryId = try resolveCategoryID(args.categoryId, in: state, fallback: current.categoryID)
        let title = args.title ?? current.title
        let updated = try CalendarItem(
            id: current.id,
            kind: current.kind,
            title: title,
            categoryID: categoryId,
            schedule: schedule,
            creationTimeZoneIdentifier: current.creationTimeZoneIdentifier,
            priority: priority,
            isPinned: pinned,
            notes: args.notes ?? current.notes,
            untimedRank: current.untimedRank,
            completedAt: current.completedAt,
            createdAt: current.createdAt,
            updatedAt: Date()
        )
        let result = try await gateway.send(
            .calendar(.updateItem(updated)),
            undoLabel: "MCP 修改「\(updated.title)」"
        )
        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "item": MCPFormatting.fullItem(updated, categories: state.calendar.categories)
            ])
        }
    }

    private func moveItems(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(MoveItemsArgs.self)
        let ids = try args.itemIds.map { try MCPArgParsing.uuid($0, field: "item_ids") }
        let date = try MCPArgParsing.calendarDate(args.date, field: "date")
        let result = try await gateway.send(
            .calendar(.moveItems(ids, to: date)),
            undoLabel: "MCP 移动 \(ids.count) 条日程到 \(MCPFormatting.date(date))"
        )
        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "moved": .int(Int64(ids.count)),
                "date": .string(args.date)
            ])
        }
    }

    private func setTaskCompleted(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(SetTaskCompletedArgs.self)
        let command: CalendarCommand
        let target: MCPJSON
        if let itemId = args.itemId {
            guard args.seriesId == nil, args.date == nil else {
                throw MCPArgParsing.invalidParams("item_id 不能与 series_id/date 混用；重复系列实例请传 series_id + date。")
            }
            let id = try MCPArgParsing.uuid(itemId, field: "item_id")
            command = .setTaskCompleted(id, args.completed ? Date() : nil)
            target = .object(["item_id": .string(itemId)])
        } else if let seriesId = args.seriesId, let dateRaw = args.date {
            let seriesUUID = try MCPArgParsing.uuid(seriesId, field: "series_id")
            let date = try MCPArgParsing.calendarDate(dateRaw, field: "date")
            command = .setOccurrenceCompleted(
                OccurrenceKey(seriesID: seriesUUID, originalDate: date),
                args.completed ? Date() : nil
            )
            target = .object([
                "series_id": .string(seriesId),
                "date": .string(dateRaw)
            ])
        } else {
            throw MCPArgParsing.invalidParams("需要提供 item_id（单次条目），或 series_id + date（重复系列实例）。")
        }
        let result = try await gateway.send(
            .calendar(command),
            undoLabel: args.completed ? "MCP 完成任务" : "MCP 重新打开任务"
        )
        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "target": target,
                "completed": .bool(args.completed)
            ])
        }
    }

    private func deleteItem(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(DeleteItemArgs.self)
        let id = try MCPArgParsing.uuid(args.id, field: "id")
        let state = await gateway.currentState()
        let title = state.calendar.items[id]?.title
        let result = try await gateway.send(
            .calendar(.deleteItem(id)),
            undoLabel: "MCP 删除「\(title ?? args.id)」"
        )
        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "deleted": .object([
                    "id": .string(args.id),
                    "title": title.map { .string($0) } ?? .null
                ])
            ])
        }
    }

    private func reorderUntimedItems(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(ReorderUntimedArgs.self)
        let date = try MCPArgParsing.calendarDate(args.date, field: "date")
        let ids = try args.orderedIds.map { try MCPArgParsing.uuid($0, field: "ordered_ids") }
        let result = try await gateway.send(
            .calendar(.reorderUntimedItems(on: date, orderedIDs: ids)),
            undoLabel: "MCP 调整 \(MCPFormatting.date(date)) 的全天条目顺序"
        )
        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "reordered": .int(Int64(ids.count)),
                "date": .string(args.date)
            ])
        }
    }

    // MARK: Series tools

    private func createSeries(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(CreateSeriesArgs.self)
        let weekdays = try MCPArgParsing.weekdays(args.weekdays) ?? []
        let startDate = try MCPArgParsing.calendarDate(args.startDate, field: "start_date")
        let recurrenceEnd = try args.recurrenceEndDate.map {
            try MCPArgParsing.calendarDate($0, field: "recurrence_end_date")
        }
        let times = try MCPArgParsing.timePair(start: args.startTime, end: args.endTime)
        let priority = try MCPArgParsing.priority(args.priority) ?? .none
        let state = await gateway.currentState()
        let categoryId = try resolveCategoryID(args.categoryId, in: state)
        let series = try WeeklySeries(
            id: UUID(),
            kind: .task,
            title: args.title,
            categoryID: categoryId,
            ruleStartDate: startDate,
            recurrenceEndDate: recurrenceEnd,
            weekdays: weekdays,
            durationDays: args.durationDays ?? 1,
            startTime: times.start,
            endTime: times.end,
            priority: priority,
            isPinned: args.pinned ?? false,
            notes: args.notes ?? "",
            createdAt: Date(),
            updatedAt: Date()
        )
        let result = try await gateway.send(
            .calendar(.createSeries(series)),
            undoLabel: "MCP 创建重复系列「\(series.title)」"
        )
        return try committed(result) {
            .object([
                "ok": .bool(true),
                "created": .bool(true),
                "series": MCPFormatting.series(series, categories: state.calendar.categories)
            ])
        }
    }

    private func modifySeries(_ arguments: MCPJSON) async throws -> MCPJSON {
        let args = try arguments.decode(ModifySeriesArgs.self)
        let seriesId = try MCPArgParsing.uuid(args.seriesId, field: "series_id")
        let date = try MCPArgParsing.calendarDate(args.date, field: "date")
        let scope: SeriesScope
        switch args.scope {
        case "this_only": scope = .onlyThis
        case "this_and_future": scope = .thisAndFuture
        default:
            throw MCPArgParsing.invalidParams("scope 只接受 this_only / this_and_future，收到：\(args.scope)")
        }
        let edit: SeriesEdit
        switch args.action {
        case "delete":
            edit = .delete
        case "patch":
            edit = .patch(try buildSeriesPatch(args))
        default:
            throw MCPArgParsing.invalidParams("action 只接受 patch / delete，收到：\(args.action)")
        }

        let stateBefore = await gateway.currentState()
        let result = try await gateway.send(
            .calendar(.mutateSeries(
                OccurrenceKey(seriesID: seriesId, originalDate: date),
                scope: scope,
                edit: edit,
                newSeriesID: UUID()
            )),
            undoLabel: "MCP 修改重复系列（\(args.scope)）"
        )
        let stateAfter = await gateway.currentState()
        let newSeriesID = Set(stateAfter.calendar.recurrence.series.keys)
            .subtracting(stateBefore.calendar.recurrence.series.keys)
            .first

        return try mutationOutcome(result) {
            .object([
                "ok": .bool(true),
                "scope": .string(args.scope),
                "action": .string(args.action),
                "new_series_id": newSeriesID.map { MCPJSON.string($0.uuidString) } ?? .null
            ])
        }
    }

    private func buildSeriesPatch(_ args: ModifySeriesArgs) throws -> SeriesPatch {
        let weekdays = try MCPArgParsing.weekdays(args.weekdays)
        var recurrenceEnd = OptionalPatch<CalendarDate>.unchanged
        if args.clearRecurrenceEndDate == true {
            recurrenceEnd = .clear
        } else if let raw = args.recurrenceEndDate {
            recurrenceEnd = .set(try MCPArgParsing.calendarDate(raw, field: "recurrence_end_date"))
        }

        var startTime = OptionalPatch<MinuteOfDay>.unchanged
        var endTime = OptionalPatch<MinuteOfDay>.unchanged
        if args.clearTimes == true {
            startTime = .clear
            endTime = .clear
        } else if args.startTime != nil || args.endTime != nil {
            let pair = try MCPArgParsing.timePair(start: args.startTime, end: args.endTime)
            if let start = pair.start { startTime = .set(start) }
            if let end = pair.end { endTime = .set(end) }
        }

        let displayedStartDate = try args.startDate.map {
            try MCPArgParsing.calendarDate($0, field: "start_date")
        }
        return SeriesPatch(
            title: args.title,
            categoryID: try args.categoryId.map { try MCPArgParsing.uuid($0, field: "category_id") },
            weekdays: weekdays,
            recurrenceEndDate: recurrenceEnd,
            displayedStartDate: displayedStartDate,
            durationDays: args.durationDays,
            startTime: startTime,
            endTime: endTime,
            priority: try MCPArgParsing.priority(args.priority),
            isPinned: args.pinned,
            notes: args.notes
        )
    }

    // MARK: Undo

    private func undo() async throws -> MCPJSON {
        _ = try await gateway.undo()
        return .object([
            "ok": .bool(true),
            "undone": .bool(true)
        ])
    }

    // MARK: Shared helpers

    private func resolveCategoryID(
        _ raw: String?,
        in state: WorkspaceState,
        fallback: UUID? = nil
    ) throws -> UUID {
        guard let raw else { return fallback ?? state.calendar.uncategorizedID }
        guard let id = UUID(uuidString: raw), state.calendar.categories[id] != nil else {
            throw MCPGatewayError(
                code: "unknown_category",
                message: "分类不存在：\(raw)。先用 jelly_list_categories 查看可用分类。"
            )
        }
        return id
    }

    /// A create must change the workspace; anything else is an error.
    private func committed(_ result: MCPMutationResult, payload: () -> MCPJSON) throws -> MCPJSON {
        switch result.status {
        case .committed:
            return payload()
        case let .noChange(reason):
            throw MCPGatewayError(code: "no_change", message: "命令未产生任何变化：\(reason)")
        case let .conflict(description):
            throw MCPGatewayError(code: "conflict", message: description)
        case let .persistenceBlocked(description):
            throw MCPGatewayError(code: "persistence_blocked", message: description)
        case let .uncertain(description):
            throw MCPGatewayError(code: "uncertain", message: description)
        }
    }

    /// An update may legitimately be a no-op (same values submitted again).
    private func mutationOutcome(_ result: MCPMutationResult, payload: () -> MCPJSON) throws -> MCPJSON {
        switch result.status {
        case .committed:
            var payloadObject = payload().objectValue ?? [:]
            payloadObject["changed"] = .bool(true)
            return .object(payloadObject)
        case let .noChange(reason):
            return .object([
                "ok": .bool(true),
                "changed": .bool(false),
                "reason": .string(reason)
            ])
        case let .conflict(description):
            throw MCPGatewayError(code: "conflict", message: description)
        case let .persistenceBlocked(description):
            throw MCPGatewayError(code: "persistence_blocked", message: description)
        case let .uncertain(description):
            throw MCPGatewayError(code: "uncertain", message: description)
        }
    }

    static func describe(_ error: Error) -> (code: String, message: String) {
        switch error {
        case let gatewayError as MCPGatewayError:
            return (gatewayError.code, gatewayError.message)
        case let reducerError as WorkspaceReducerError:
            return describe(reducerError)
        case DomainValidationError.emptyTitle:
            return ("empty_title", "标题不能为空。")
        case DomainValidationError.invalidDateRange:
            return ("invalid_date_range", "日期范围无效：结束日期不能早于开始日期。")
        case DomainValidationError.invalidTimeRange:
            return ("invalid_time_range", "时间无效：同一天的结束时间必须晚于开始时间，且起止时间必须同时提供。")
        case DomainValidationError.eventCannotComplete:
            return ("event_cannot_complete", "该对象不支持完成状态。")
        case DomainValidationError.invalidTimeZoneIdentifier:
            return ("invalid_time_zone", "时区标识无效。")
        case DomainValidationError.emptyWeekdaySet:
            return ("empty_weekday_set", "重复系列至少要选择一个星期。")
        case DomainValidationError.invalidRecurrenceEnd:
            return ("invalid_recurrence_end", "重复结束日期不能早于系列开始日期。")
        case DomainValidationError.noOccurrenceInRange:
            return ("no_occurrence_in_range", "在开始与结束日期之间没有任何命中所选星期的实例。")
        case ReducerError.missingItem:
            return ("not_found", "日程条目不存在，可能已被删除。")
        case ReducerError.missingSeries:
            return ("not_found", "重复系列不存在。")
        case ReducerError.unknownCategory:
            return ("unknown_category", "分类不存在。")
        case ReducerError.duplicateCategoryName:
            return ("duplicate_category_name", "已存在同名分类。")
        case ReducerError.invalidCategoryColor:
            return ("invalid_category_color", "分类颜色格式无效。")
        case ReducerError.protectedCategory:
            return ("protected_category", "「未分类」是受保护分类，不能修改或删除。")
        case ReducerError.invalidMigrationTarget:
            return ("invalid_migration_target", "删除分类时指定的迁移目标无效。")
        case ReducerError.invalidCategoryOrder:
            return ("invalid_category_order", "分类排序列表无效。")
        case ReducerError.eventCannotComplete:
            return ("event_cannot_complete", "该对象不支持完成状态。")
        case ReducerError.invalidState:
            return ("invalid_state", "领域状态校验失败。")
        case let decoding as DecodingError:
            return ("invalid_params", describeDecoding(decoding))
        default:
            return ("internal_error", String(describing: error))
        }
    }

    /// The workspace reducer wraps calendar-domain failures, so unwrap them
    /// before mapping to tool error codes.
    private static func describe(_ error: WorkspaceReducerError) -> (code: String, message: String) {
        switch error {
        case let .calendarFailure(inner):
            return describe(inner)
        case let .seriesMutationFailure(inner):
            return describe(inner)
        case let .relationMigrationFailure(inner):
            return ("invalid_state", String(describing: inner))
        case .missingCalendarTarget:
            return ("not_found", "日历目标不存在。")
        case .invalidInputWorkspace, .finalValidationFailed, .invalidDraftSubmission,
             .invalidLinkedBlockDispositions, .taskBlockMissingOrNotTask, .taskTitleMismatch,
             .taskCompletionMismatch:
            return ("invalid_state", "领域状态校验失败。")
        case .rawCalendarCategoryCommandRejected:
            return ("invalid_command", "分类修改必须走工作区命令，而不是日历命令。")
        case .invalidNote, .invalidInspiration, .missingNote, .duplicateNote,
             .missingInspiration, .duplicateInspiration, .duplicateTaskBlockLink,
             .fatalConsistencyIssues, .invalidConsistencyRepair, .invalidDecompositionPlan,
             .invalidLegacyAuthorization, .invalidMaterialDigestStage,
             .invalidPermanentDeleteAuthorization, .invalidRestoreMetadata,
             .legacyDiagnosticsRequireConfirmation, .permanentDeleteRequiresArchivedSubject,
             .primaryReplacementDispositionRequired, .revisionOverflow,
             .linkedTaskDispositionRequired, .unexpectedLinkedTaskDisposition,
             .unexpectedPrimaryReplacementDisposition:
            return ("internal_error", String(describing: error))
        }
    }

    private static func describe(_ error: SeriesMutationError) -> (code: String, message: String) {
        switch error {
        case .unknownSeries, .unknownOccurrence:
            return ("not_found", "重复系列或实例不存在。")
        case .invalidOnlyThisRulePatch:
            return ("invalid_params", "this_only 只支持显示层字段（标题/时间/分类/优先级/备注），改星期或日期请用 this_and_future。")
        case .duplicateSeriesID:
            return ("invalid_state", "新系列 ID 冲突。")
        }
    }

    private static func describeDecoding(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, _):
            return "缺少必需参数：\(key.stringValue)。"
        case let .typeMismatch(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "参数类型不正确。" : "参数 \(path) 类型不正确。"
        case let .valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "参数值不能为空。" : "参数 \(path) 不能为空。"
        case .dataCorrupted:
            return "参数不是有效的 JSON。"
        @unknown default:
            return "参数解析失败。"
        }
    }
}

// MARK: - Rendering

extension MCPFormatting {
    /// The stable reference the UI also uses: items by UUID, series instances
    /// by (series, original date).
    static func entryID(_ id: ProjectedEntryID) -> String {
        switch id {
        case let .item(itemID):
            return "item:\(itemID.uuidString)"
        case let .occurrence(key):
            return "occurrence:\(key.seriesID.uuidString):\(date(key.originalDate))"
        }
    }

    static func entry(_ entry: ProjectedEntry, categories: [UUID: CalendarCategory]) -> MCPJSON {
        var payload: [String: MCPJSON] = [
            "id": .string(entryID(entry.id)),
            "title": .string(entry.title),
            "start_date": .string(date(entry.schedule.startDate)),
            "end_date": .string(date(entry.schedule.endDate)),
            "start_time": optionalTime(entry.schedule.startTime),
            "end_time": optionalTime(entry.schedule.endTime),
            "timed": .bool(entry.schedule.startTime != nil),
            "multi_day": .bool(entry.schedule.durationDays > 1),
            "completed": .bool(entry.completedAt != nil),
            "completed_at": optionalInstant(entry.completedAt),
            "priority": priority(entry.priority),
            "pinned": .bool(entry.isPinned),
            "category_id": .string(entry.categoryID.uuidString),
            "category_name": categories[entry.categoryID].map { .string($0.name) } ?? .null,
            "notes": .string(entry.notes),
            "created_at": .string(instant(entry.createdAt))
        ]
        switch entry {
        case let .item(item):
            payload["type"] = .string("item")
            payload["item_id"] = .string(item.id.uuidString)
        case let .occurrence(occurrence):
            payload["type"] = .string("occurrence")
            payload["series_id"] = .string(occurrence.key.seriesID.uuidString)
            payload["occurrence_date"] = .string(date(occurrence.key.originalDate))
        }
        return .object(payload)
    }

    static func fullItem(_ item: CalendarItem, categories: [UUID: CalendarCategory]) -> MCPJSON {
        .object([
            "id": .string(item.id.uuidString),
            "title": .string(item.title),
            "start_date": .string(date(item.schedule.startDate)),
            "end_date": .string(date(item.schedule.endDate)),
            "start_time": optionalTime(item.schedule.startTime),
            "end_time": optionalTime(item.schedule.endTime),
            "timed": .bool(item.schedule.startTime != nil),
            "multi_day": .bool(item.schedule.durationDays > 1),
            "completed": .bool(item.completedAt != nil),
            "completed_at": optionalInstant(item.completedAt),
            "priority": priority(item.priority),
            "pinned": .bool(item.isPinned),
            "category_id": .string(item.categoryID.uuidString),
            "category_name": categories[item.categoryID].map { .string($0.name) } ?? .null,
            "notes": .string(item.notes),
            "untimed_rank": .int(Int64(item.untimedRank)),
            "created_at": .string(instant(item.createdAt)),
            "updated_at": .string(instant(item.updatedAt))
        ])
    }

    static func series(_ series: WeeklySeries, categories: [UUID: CalendarCategory]) -> MCPJSON {
        .object([
            "id": .string(series.id.uuidString),
            "title": .string(series.title),
            "weekdays": .array(series.weekdays.sorted { $0.rawValue < $1.rawValue }.map { .string(weekdayName($0)) }),
            "rule_start_date": .string(date(series.ruleStartDate)),
            "recurrence_end_date": optionalDate(series.recurrenceEndDate),
            "duration_days": .int(Int64(series.durationDays)),
            "start_time": optionalTime(series.startTime),
            "end_time": optionalTime(series.endTime),
            "timed": .bool(series.startTime != nil),
            "priority": priority(series.priority),
            "pinned": .bool(series.isPinned),
            "category_id": .string(series.categoryID.uuidString),
            "category_name": categories[series.categoryID].map { .string($0.name) } ?? .null,
            "notes": .string(series.notes),
            "created_at": .string(instant(series.createdAt))
        ])
    }

    static func category(_ category: CalendarCategory, isUncategorized: Bool) -> MCPJSON {
        .object([
            "id": .string(category.id.uuidString),
            "name": .string(category.name),
            "color_hex": .string(category.colorHex),
            "sort_index": .int(Int64(category.sortIndex)),
            "is_uncategorized": .bool(isUncategorized)
        ])
    }

    static func searchRecord(_ record: WorkspaceSearchRecord, state: WorkspaceState) -> MCPJSON {
        let (objectType, id): (String, String)
        var title: String?
        switch record.objectID {
        case let .calendarItem(itemID):
            objectType = "calendarItem"
            id = itemID.uuidString
            title = state.calendar.items[itemID]?.title
        case let .note(noteID):
            objectType = "note"
            id = noteID.rawValue.uuidString
            title = state.notes[noteID]?.title
        case let .inspiration(inspirationID):
            objectType = "inspiration"
            id = inspirationID.rawValue.uuidString
            title = state.inspirations[inspirationID]?.resolvedMetadata?.title
        }
        let preview = record.normalizedText.count > 200
            ? String(record.normalizedText.prefix(200)) + "…"
            : record.normalizedText
        return .object([
            "type": .string(objectType),
            "id": .string(id),
            "title": title.map { .string($0) } ?? .null,
            "preview": .string(preview),
            "category_id": record.categoryID.map { .string($0.uuidString) } ?? .null,
            "is_archived": .bool(record.isArchived)
        ])
    }
}
