import CalendarDomain
import Foundation
import JellyMCP
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("JellyMCP 网关 × App Store 集成")
@MainActor
struct JellyMCPCalGatewayTests {
    private func makeToolbox() async throws -> (JellyMCPToolbox, WorkspaceStore) {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = JellyMCPCalGateway(store: store)
        return (JellyMCPToolbox(gateway: gateway), store)
    }

    private func call(
        _ toolbox: JellyMCPToolbox,
        _ name: String,
        _ arguments: [String: MCPJSON]
    ) async throws -> [String: MCPJSON] {
        let result = await toolbox.call(name: name, arguments: .object(arguments))
        return try #require(MCPJSON.parse(Data(result.text.utf8)).objectValue)
    }

    @Test("经 MCP 创建的条目进入真实 Store 并持久化到仓储")
    func createThroughRealStore() async throws {
        let (toolbox, store) = try await makeToolbox()
        let payload = try await call(toolbox, "jelly_create_item", [
            "title": .string("MCP 创建的日程"),
            "date": .string("2026-03-10")
        ])
        #expect(payload["ok"] == .bool(true))
        #expect(store.calendarState.items.count == 1)
        #expect(store.canUndo)
    }

    @Test("完成任务后 jelly_undo 走的是 App 撤销栈")
    func completeThenUndo() async throws {
        let (toolbox, store) = try await makeToolbox()
        let created = try await call(toolbox, "jelly_create_item", [
            "title": .string("晨跑"),
            "date": .string("2026-03-10")
        ])
        let itemID = try #require(created["item"]?.objectValue?["id"]?.stringValue)

        let completed = try await call(toolbox, "jelly_set_task_completed", [
            "item_id": .string(itemID),
            "completed": .bool(true)
        ])
        #expect(completed["ok"] == .bool(true))
        #expect(store.calendarState.items[UUID(uuidString: itemID)!]?.completedAt != nil)

        let undone = try await call(toolbox, "jelly_undo", [:])
        #expect(undone["ok"] == .bool(true))
        #expect(store.calendarState.items[UUID(uuidString: itemID)!]?.completedAt == nil)
    }

    @Test("move_items 改期保留时间")
    func moveItems() async throws {
        let (toolbox, store) = try await makeToolbox()
        let created = try await call(toolbox, "jelly_create_item", [
            "title": .string("会议"),
            "date": .string("2026-03-10"),
            "start_time": .string("14:00"),
            "end_time": .string("15:00")
        ])
        let itemID = try #require(created["item"]?.objectValue?["id"]?.stringValue)

        let moved = try await call(toolbox, "jelly_move_items", [
            "item_ids": .array([.string(itemID)]),
            "date": .string("2026-03-11")
        ])
        #expect(moved["ok"] == .bool(true))
        let item = try #require(store.calendarState.items[UUID(uuidString: itemID)!])
        #expect(item.schedule.startDate == CalendarDate(year: 2026, month: 3, day: 11))
        #expect(item.schedule.startTime?.value == 840)
    }

    @Test("search 能找到刚创建的日程")
    func searchFindsCreatedItem() async throws {
        let (toolbox, _) = try await makeToolbox()
        _ = try await call(toolbox, "jelly_create_item", [
            "title": .string("健身 30 分钟"),
            "date": .string("2026-03-10"),
            "notes": .string("力量训练")
        ])
        let found = try await call(toolbox, "jelly_search", ["query": .string("健身")])
        let results = try #require(found["results"]?.arrayValue)
        #expect(results.count == 1)
        #expect(results.first?.objectValue?["type"] == .string("calendarItem"))
    }

    @Test("删除不存在的条目返回 not_found")
    func deleteMissingItem() async throws {
        let (toolbox, _) = try await makeToolbox()
        let payload = try await call(toolbox, "jelly_delete_item", [
            "id": .string(UUID().uuidString)
        ])
        #expect(payload["ok"] == .bool(false))
        #expect(payload["error"]?.objectValue?["code"] == .string("not_found"))
    }

    @Test("跨天移动排序不影响合法顺序校验")
    func reorderUntimed() async throws {
        let (toolbox, store) = try await makeToolbox()
        let first = try await call(toolbox, "jelly_create_item", [
            "title": .string("A"),
            "date": .string("2026-03-10")
        ])
        let second = try await call(toolbox, "jelly_create_item", [
            "title": .string("B"),
            "date": .string("2026-03-10")
        ])
        let firstID = try #require(first["item"]?.objectValue?["id"]?.stringValue)
        let secondID = try #require(second["item"]?.objectValue?["id"]?.stringValue)

        let reordered = try await call(toolbox, "jelly_reorder_untimed_items", [
            "date": .string("2026-03-10"),
            "ordered_ids": .array([.string(secondID), .string(firstID)])
        ])
        #expect(reordered["ok"] == .bool(true))
        #expect(store.calendarState.items[UUID(uuidString: secondID)!]?.untimedRank == 0)
        #expect(store.calendarState.items[UUID(uuidString: firstID)!]?.untimedRank == 1)
    }
}
