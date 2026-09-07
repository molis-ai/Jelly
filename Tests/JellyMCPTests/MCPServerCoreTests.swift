import CalendarDomain
import Foundation
import JellyMCP
import Testing

@Suite("MCP 服务器核心分发")
@MainActor
struct MCPServerCoreTests {
    private let gateway = MockGateway()

    private func call(
        _ name: String,
        _ arguments: [String: MCPJSON],
        gateway: MockGateway? = nil
    ) async throws -> (result: [String: MCPJSON], payload: [String: MCPJSON], isError: Bool) {
        let core = makeTestCore(gateway: gateway ?? self.gateway)
        let response = try await handleAndParse(
            core,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(1),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string(name),
                    "arguments": .object(arguments)
                ])
            ])
        )
        let result = try #require(response["result"]?.objectValue)
        let content = try #require(result["content"]?.arrayValue)
        let text = try #require(content.first?.objectValue?["text"]?.stringValue)
        let payload = try #require(MCPJSON.parse(Data(text.utf8)).objectValue)
        return (result, payload, result["isError"] == .bool(true))
    }

    @Test("initialize 回显已知协议版本并声明 tools 能力")
    func initialize() async throws {
        let core = makeTestCore(gateway: gateway)
        let response = try await handleAndParse(
            core,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(1),
                "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2025-03-26"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("test"), "version": .string("0")])
                ])
            ])
        )
        let result = try #require(response["result"]?.objectValue)
        #expect(result["protocolVersion"] == .string("2025-03-26"))
        #expect(result["serverInfo"]?.objectValue?["name"] == .string("jelly-test"))
        #expect(result["capabilities"]?.objectValue?["tools"] != nil)
    }

    @Test("initialize 未知版本回落到当前版本")
    func initializeUnknownVersion() async throws {
        let core = makeTestCore(gateway: gateway)
        let response = try await handleAndParse(
            core,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(1),
                "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("1999-01-01")])
            ])
        )
        #expect(try #require(response["result"]?.objectValue)["protocolVersion"] == .string(MCPProtocolVersion.current))
    }

    @Test("通知不产生响应，ping 返回空结果")
    func notificationsAndPing() async throws {
        let core = makeTestCore(gateway: gateway)
        let notification = await core.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notification == nil)

        let ping = try await handleAndParse(
            core,
            .object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("ping")])
        )
        #expect(ping["result"] == .object([:]))
    }

    @Test("tools/list 返回 13 个工具且都带 object schema")
    func toolsList() async throws {
        let core = makeTestCore(gateway: gateway)
        let response = try await handleAndParse(
            core,
            .object(["jsonrpc": .string("2.0"), "id": .int(3), "method": .string("tools/list")])
        )
        let tools = try #require(response["result"]?.objectValue?["tools"]?.arrayValue)
        #expect(tools.count == 13)
        let names = Set(tools.compactMap { $0.objectValue?["name"]?.stringValue })
        #expect(names.contains("jelly_create_item"))
        #expect(names.contains("jelly_list_items"))
        #expect(names.contains("jelly_undo"))
        for tool in tools {
            #expect(try #require(tool.objectValue?["inputSchema"]?.objectValue)["type"] == .string("object"))
        }
    }

    @Test("未知方法与未知工具返回协议错误")
    func protocolErrors() async throws {
        let core = makeTestCore(gateway: gateway)
        let unknownMethod = try await handleAndParse(
            core,
            .object(["jsonrpc": .string("2.0"), "id": .int(4), "method": .string("resources/list")])
        )
        #expect(unknownMethod["error"]?.objectValue?["code"] == .int(-32601))

        let unknownTool = try await handleAndParse(
            core,
            .object([
                "jsonrpc": .string("2.0"),
                "id": .int(5),
                "method": .string("tools/call"),
                "params": .object(["name": .string("jelly_nope")])
            ])
        )
        #expect(unknownTool["error"]?.objectValue?["code"] == .int(-32602))
    }

    @Test("创建日程 → 列表可见 → 撤销消失")
    func createListUndo() async throws {
        let created = try await call("jelly_create_item", [
            "title": .string("写周报"),
            "date": .string("2026-03-10"),
            "start_time": .string("09:00"),
            "end_time": .string("10:00")
        ])
        #expect(!created.isError)
        #expect(created.payload["ok"] == .bool(true))
        let itemID = try #require(created.payload["item"]?.objectValue?["id"]?.stringValue)
        #expect(gateway.state.calendar.items.count == 1)
        #expect(gateway.state.calendar.items.values.first?.schedule.startTime?.value == 540)

        let listed = try await call("jelly_list_items", [
            "date": .string("2026-03-10"),
            "span": .string("day")
        ])
        #expect(!listed.isError)
        let entries = try #require(listed.payload["items"]?.arrayValue)
        #expect(entries.count == 1)
        #expect(entries.first?.objectValue?["id"]?.stringValue == "item:\(itemID)")
        #expect(entries.first?.objectValue?["timed"] == .bool(true))

        let undone = try await call("jelly_undo", [:])
        #expect(!undone.isError)
        #expect(gateway.state.calendar.items.isEmpty)
    }

    @Test("领域校验失败映射为带错误码的 isError 结果")
    func validationErrors() async throws {
        let emptyTitle = try await call("jelly_create_item", [
            "title": .string("   "),
            "date": .string("2026-03-10")
        ])
        #expect(emptyTitle.isError)
        #expect(emptyTitle.payload["error"]?.objectValue?["code"] == .string("empty_title"))

        let halfTimes = try await call("jelly_create_item", [
            "title": .string("只有开始时间"),
            "date": .string("2026-03-10"),
            "start_time": .string("09:00")
        ])
        #expect(halfTimes.isError)
        #expect(halfTimes.payload["error"]?.objectValue?["code"] == .string("invalid_params"))

        let unknownCategory = try await call("jelly_create_item", [
            "title": .string("错分类"),
            "date": .string("2026-03-10"),
            "category_id": .string(UUID().uuidString)
        ])
        #expect(unknownCategory.isError)
        #expect(unknownCategory.payload["error"]?.objectValue?["code"] == .string("unknown_category"))
    }

    @Test("撤销栈为空时 jelly_undo 报错")
    func undoWhenEmpty() async throws {
        let undone = try await call("jelly_undo", [:])
        #expect(undone.isError)
        #expect(undone.payload["error"]?.objectValue?["code"] == .string("nothing_to_undo"))
    }

    @Test("重复系列创建后按周展开，thisOnly 删除单次实例")
    func seriesCreateAndModify() async throws {
        let created = try await call("jelly_create_series", [
            "title": .string("周会"),
            "weekdays": .array([.int(1)]),
            "start_date": .string("2026-03-02")
        ])
        #expect(!created.isError)
        let seriesID = try #require(created.payload["series"]?.objectValue?["id"]?.stringValue)

        let monday1 = try await call("jelly_list_items", ["date": .string("2026-03-02")])
        let monday2 = try await call("jelly_list_items", ["date": .string("2026-03-09")])
        #expect(try #require(monday1.payload["items"]?.arrayValue).count == 1)
        #expect(try #require(monday2.payload["items"]?.arrayValue).count == 1)

        let modified = try await call("jelly_modify_series", [
            "series_id": .string(seriesID),
            "date": .string("2026-03-09"),
            "scope": .string("this_only"),
            "action": .string("delete")
        ])
        #expect(!modified.isError)
        let afterMonday = try await call("jelly_list_items", ["date": .string("2026-03-09")])
        let afterNext = try await call("jelly_list_items", ["date": .string("2026-03-16")])
        #expect(try #require(afterMonday.payload["items"]?.arrayValue).isEmpty)
        #expect(try #require(afterNext.payload["items"]?.arrayValue).count == 1)
    }

    @Test("批量帧：通知不回包，请求逐个回包")
    func batchFrames() async throws {
        let core = makeTestCore(gateway: gateway)
        let response = await core.handle(Data(
            #"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":9,"method":"ping"}]"#.utf8
        ))
        let parsed = try #require(response.map { try MCPJSON.parse($0) })
        let array = try #require(parsed.arrayValue)
        #expect(array.count == 1)
        #expect(array.first?.objectValue?["id"] == .int(9))
    }
}
