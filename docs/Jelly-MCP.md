# Jelly MCP 服务器

Jelly 内置一个 MCP（Model Context Protocol）服务器，把日历和日程的核心操作以标准 MCP 工具暴露给 AI 客户端（Claude Code、Claude Desktop、Cursor 等）。AI 可以直接查看、创建、修改、完成、删除 Jelly 的日程，所有写入都走 App 内部同一条经过校验、可撤销的事务路径。

## 工作方式

```
stdio 客户端 ──> jelly-mcp（随 Jelly.app 安装的桥接程序）──┐
HTTP 客户端 ──────────────────────────────────────────┴──> Jelly App 内嵌 MCP 端点
                                                              │
                                                    WorkspaceStore（与 UI 同一事务队列 + 撤销栈）
```

- **HTTP 端点**：`POST http://127.0.0.1:<端口>/mcp`，JSON-RPC 2.0，仅支持 `initialize` / `tools/list` / `tools/call` / `ping`。
- **stdio 桥**：`/Applications/Jelly.app/Contents/MacOS/jelly-mcp`，把 stdio 客户端的每行 JSON-RPC 原样转发到上面的 HTTP 端点；Jelly 没在运行时会尝试用 `open -b com.oreal.personalcalendar` 自动拉起。
- **安全**：端点只绑定 127.0.0.1（不进本机网络，不触发防火墙/隐私提示），每次启动生成随机令牌。端口和令牌写入数据目录的 `mcp-server.json`（权限 600）：
  - 日常版：`~/Library/Application Support/PersonalCalendar/mcp-server.json`
  - 预览版：`~/Library/Application Support/PersonalCalendarPreview/mcp-server.json`
- **撤销**：MCP 的每次修改都进 App 的 ⌘Z 撤销栈，也可以在会话里直接调用 `jelly_undo`。
- **开关**：Jelly 设置 → MCP 服务器，可随时关闭；关闭后 endpoint 文件会被删除。

前提：**Jelly 必须在运行**。MCP 服务器随主窗口加载自动启动（默认开启）。

## 接入 Claude Code（HTTP 直连）

启动 Jelly 后，打开 设置 → MCP 服务器，点「复制」拿到现成命令（令牌以页面显示为准）：

```bash
claude mcp add --transport http jelly http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <令牌>"
```

## 接入 Claude Desktop（stdio 桥）

编辑 `claude_desktop_config.json`（设置 → 开发者 → 编辑配置）：

```json
{
  "mcpServers": {
    "jelly": {
      "command": "/Applications/Jelly.app/Contents/MacOS/jelly-mcp"
    }
  }
}
```

桥接程序自己会从 `mcp-server.json` 读取端口和令牌；如需覆盖，可设置环境变量 `JELLY_MCP_URL`（完整端点 URL）或 `JELLY_MCP_PORT`，外加 `JELLY_MCP_TOKEN`。

## 接入其他客户端（Cursor 等）

任何支持 Streamable HTTP 传输的客户端都能直连：URL `http://127.0.0.1:<端口>/mcp`，Header `Authorization: Bearer <令牌>`。

## 工具一览（13 个）

### 读取

| 工具 | 说明 |
|------|------|
| `jelly_list_items` | 列出某天/某周（周一起）/某月的日程。重复系列自动展开为实例（occurrence），按置顶、优先级、时间排序 |
| `jelly_get_item` | 按 id 查看单次条目完整信息（备注 markdown、时间戳等） |
| `jelly_search` | 跨日程、笔记、灵感做子串搜索，返回对象类型与 id |
| `jelly_list_categories` | 列出分类（创建/修改日程时引用 `category_id`） |

### 写入（全部可撤销）

| 工具 | 说明 |
|------|------|
| `jelly_create_item` | 创建条目。`start_time`+`end_time` 同时给才算带时间；`end_date` 支持跨天 |
| `jelly_update_item` | 改标题/备注/时间/分类/优先级/置顶。改日期请用 `jelly_move_items` |
| `jelly_move_items` | 批量改期（保留时长与时间） |
| `jelly_set_task_completed` | 完成/重开。单次条目传 `item_id`；系列实例传 `series_id`+`date` |
| `jelly_delete_item` | 删除条目 |
| `jelly_reorder_untimed_items` | 设置某天全天条目的手动顺序 |
| `jelly_create_series` | 创建每周重复系列（`weekdays` 1=周一…7=周日） |
| `jelly_modify_series` | 以某实例为锚点修改系列：`scope=this_only`（单实例）或 `this_and_future`（拆分出新系列），`action=patch/delete` |
| `jelly_undo` | 撤销最近一次修改（与 App 内 ⌘Z 同一栈） |

### 参数约定

- 日期 `YYYY-MM-DD`；时间 24 小时制 `HH:mm`。
- 优先级 `p0` / `p1` / `p2` / `none`；置顶条目会强制 P0。
- 条目 id 是 UUID；列表结果里的 `id` 带前缀（`item:<uuid>` 或 `occurrence:<seriesId>:<日期>`），引用时用 `item_id` / `series_id`+`occurrence_date` 拆开传。
- 所有工具失败时返回 `{"ok": false, "error": {"code", "message"}}` 并置 `isError`；常见错误码：`not_found`、`unknown_category`、`invalid_params`、`invalid_time_range`、`persistence_blocked`、`nothing_to_undo`。

## 故障排查

| 现象 | 处理 |
|------|------|
| 桥报「无法连接 Jelly 的 MCP 端点」 | Jelly 没在运行，或设置里 MCP 服务器被关闭；启动 Jelly 后重试 |
| HTTP 401 | 令牌不对——App 每次启动会重新生成，从设置页或 `mcp-server.json` 取最新的 |
| 硬退出（force quit / SIGTERM）后 `mcp-server.json` 残留 | 正常现象：只有 ⌘Q 会在退出时删除端点文件。残留文件里的端口已失效，桥接程序会自动拉起 Jelly 并拿到新文件 |
| 端口被占用 | 自动从 8787 起向后顺延；以设置页/`mcp-server.json` 显示的端口为准 |
| 连接被拒但 App 明明在运行 | 确认没有 `JELLY_MCP_DISABLED=1` 环境变量；查看 `mcp-server.json` 是否存在 |
| MCP 改动想反悔 | 调 `jelly_undo`，或在 App 里 ⌘Z |

## 实现位置

| 路径 | 角色 |
|------|------|
| `Sources/JellyMCP` | 协议层：JSON-RPC、分发器、13 个工具、回环 HTTP 传输 |
| `Sources/JellyMCPBridge` | `jelly-mcp` stdio 桥可执行文件 |
| `Sources/CalendarApp/MCP` | App 侧：Store 网关、服务控制器、设置页 |
