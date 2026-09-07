import Foundation

enum MCPToolSchemas {
    private static func string(_ description: String) -> MCPJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func stringEnum(_ values: [String], _ description: String) -> MCPJSON {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }

    private static func integer(_ description: String) -> MCPJSON {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> MCPJSON {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> MCPJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    private static func integerArray(_ description: String) -> MCPJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string(description)])
    }

    private static func definition(
        _ name: String,
        _ title: String,
        _ description: String,
        properties: [(String, MCPJSON)],
        required: [String] = []
    ) -> MCPToolDefinition {
        var schema: [String: MCPJSON] = [
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties))
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return MCPToolDefinition(
            name: name,
            title: title,
            description: description,
            inputSchema: .object(schema)
        )
    }

    static let all: [MCPToolDefinition] = [
        definition(
            "jelly_list_items",
            "列出日程",
            "列出 Jelly 日历上某天的日程，或某周/某月的全部日程。返回单次条目与重复系列已展开的实例（occurrence），按置顶、优先级、时间排序，含完成状态。",
            properties: [
                ("date", string("目标日期，YYYY-MM-DD。")),
                ("span", stringEnum(["day", "week", "month"], "范围：单日（默认）、包含该日的一周（周一起）、或整月。"))
            ],
            required: ["date"]
        ),
        definition(
            "jelly_get_item",
            "查看日程详情",
            "按 id 查看一个日历条目的完整信息（标题、备注 markdown、时间、分类、完成状态等）。只适用于单次条目；重复系列实例请用 jelly_list_items。",
            properties: [
                ("id", string("条目 UUID，可从 jelly_list_items 或 jelly_search 获得。"))
            ],
            required: ["id"]
        ),
        definition(
            "jelly_search",
            "全局搜索",
            "在 Jelly 的日程、笔记和灵感收集中做大小写不敏感的子串搜索，返回对象类型、id 和文本预览。",
            properties: [
                ("query", string("搜索关键词。")),
                ("kind", stringEnum(["calendarItem", "note", "inspiration"], "可选，只搜某一类对象。")),
                ("include_archived", boolean("可选，默认 false；是否包含已归档对象。"))
            ],
            required: ["query"]
        ),
        definition(
            "jelly_list_categories",
            "列出分类",
            "列出 Jelly 的全部分类（含 id、名称、颜色、排序），创建/修改日程时用 id 引用分类。",
            properties: [],
            required: []
        ),
        definition(
            "jelly_create_item",
            "创建日程",
            "创建一个日程条目。提供 start_time + end_time 即为带时间的条目，否则为全天/无时间条目；提供 end_date 可创建跨天条目。新建条目都是可完成的任务类型。",
            properties: [
                ("title", string("标题，不能为空。")),
                ("date", string("开始日期，YYYY-MM-DD。")),
                ("end_date", string("可选，结束日期（跨天条目），不能早于 date。")),
                ("start_time", string("可选，开始时间 HH:mm（24 小时制）。")),
                ("end_time", string("可选，结束时间 HH:mm；提供 start_time 时必填。")),
                ("category_id", string("可选，分类 UUID；缺省放入「未分类」。")),
                ("priority", stringEnum(["p0", "p1", "p2", "none"], "可选，优先级，默认 none。")),
                ("pinned", boolean("可选，是否置顶（置顶会强制 P0）。")),
                ("notes", string("可选，markdown 备注。"))
            ],
            required: ["title", "date"]
        ),
        definition(
            "jelly_update_item",
            "修改日程",
            "修改一个已有日历条目的标题、时间、分类、优先级、置顶或备注。改日期请用 jelly_move_items；只提供 start_time 或 end_time 其中一个会被拒绝。",
            properties: [
                ("id", string("条目 UUID。")),
                ("title", string("可选，新标题。")),
                ("notes", string("可选，新备注（整体替换）。")),
                ("start_time", string("可选，新开始时间 HH:mm。")),
                ("end_time", string("可选，新结束时间 HH:mm。")),
                ("clear_times", boolean("可选，true 表示改成全天/无时间条目。")),
                ("category_id", string("可选，新分类 UUID。")),
                ("priority", stringEnum(["p0", "p1", "p2", "none"], "可选，新优先级。")),
                ("pinned", boolean("可选，置顶或取消置顶。"))
            ],
            required: ["id"]
        ),
        definition(
            "jelly_move_items",
            "移动日程",
            "把一个或多个条目整体移动到目标日期（保留时长与时间），用于改期或把多条日程归到同一天。",
            properties: [
                ("item_ids", stringArray("要移动的条目 UUID 列表。")),
                ("date", string("目标日期，YYYY-MM-DD。"))
            ],
            required: ["item_ids", "date"]
        ),
        definition(
            "jelly_set_task_completed",
            "完成任务",
            "把一个条目标记为完成或重新打开。重复系列实例请传 series_id + date（即 occurrence 的原始日期）。",
            properties: [
                ("item_id", string("单次条目 UUID（与 series_id 二选一）。")),
                ("series_id", string("重复系列 UUID，用于标记某个实例的完成状态。")),
                ("date", string("系列实例的原始日期 YYYY-MM-DD（与 series_id 搭配）。")),
                ("completed", boolean("true=完成，false=重新打开。"))
            ],
            required: ["completed"]
        ),
        definition(
            "jelly_delete_item",
            "删除日程",
            "删除一个日历条目。App 内可用撤销恢复。",
            properties: [
                ("id", string("要删除的条目 UUID。"))
            ],
            required: ["id"]
        ),
        definition(
            "jelly_reorder_untimed_items",
            "排序全天条目",
            "设置某天无时间（全天）条目的手动顺序，ordered_ids 必须恰好是当天全部无时间条目的 id。",
            properties: [
                ("date", string("目标日期，YYYY-MM-DD。")),
                ("ordered_ids", stringArray("当天全部无时间条目的 id，按期望顺序。"))
            ],
            required: ["date", "ordered_ids"]
        ),
        definition(
            "jelly_create_series",
            "创建重复系列",
            "创建一个每周重复的日程系列：指定命中的星期（可多个）、开始日期，可选结束日期与时间。每个命中日生成一个可完成实例。",
            properties: [
                ("title", string("标题，不能为空。")),
                ("weekdays", integerArray("命中的星期，1=周一 … 7=周日，可多个。")),
                ("start_date", string("系列开始日期，YYYY-MM-DD。")),
                ("recurrence_end_date", string("可选，重复结束日期；不填则无限重复。")),
                ("duration_days", integer("可选，单次实例持续天数，默认 1。")),
                ("start_time", string("可选，开始时间 HH:mm。")),
                ("end_time", string("可选，结束时间 HH:mm；提供 start_time 时必填。")),
                ("category_id", string("可选，分类 UUID。")),
                ("priority", stringEnum(["p0", "p1", "p2", "none"], "可选，优先级。")),
                ("pinned", boolean("可选，是否置顶。")),
                ("notes", string("可选，markdown 备注（实例共享）。"))
            ],
            required: ["title", "weekdays", "start_date"]
        ),
        definition(
            "jelly_modify_series",
            "修改重复系列",
            "以某个实例为锚点修改重复系列：scope=this_only 只改该实例（仅显示层字段），this_and_future 从该实例起改系列（会拆分出新系列）；action=delete 表示删除（单个实例或该实例及以后）。",
            properties: [
                ("series_id", string("重复系列 UUID。")),
                ("date", string("锚点实例的原始日期 YYYY-MM-DD。")),
                ("scope", stringEnum(["this_only", "this_and_future"], "修改范围。")),
                ("action", stringEnum(["patch", "delete"], "patch=修改，delete=删除。")),
                ("title", string("可选，新标题。")),
                ("weekdays", integerArray("可选，新命中星期（仅 this_and_future）。")),
                ("category_id", string("可选，新分类。")),
                ("priority", stringEnum(["p0", "p1", "p2", "none"], "可选，新优先级。")),
                ("pinned", boolean("可选，置顶。")),
                ("notes", string("可选，新备注。")),
                ("recurrence_end_date", string("可选，新重复结束日期（仅 this_and_future）。")),
                ("clear_recurrence_end_date", boolean("可选，true 表示改为无限重复。")),
                ("start_date", string("可选，把系列显示起点移到该日期（仅 this_and_future）。")),
                ("duration_days", integer("可选，实例持续天数（仅 this_and_future）。")),
                ("start_time", string("可选，新开始时间。")),
                ("end_time", string("可选，新结束时间。")),
                ("clear_times", boolean("可选，true 表示改成全天。"))
            ],
            required: ["series_id", "date", "scope", "action"]
        ),
        definition(
            "jelly_undo",
            "撤销",
            "撤销最近一次对工作区的修改（与 App 内 ⌘Z 同一撤销栈），可用于回滚刚才 MCP 做的改动。",
            properties: [],
            required: []
        )
    ]
}
