import Foundation
import JellyMCP
import Testing

@Suite("MCP JSON-RPC 编解码")
struct MCPJSONRPCTests {
    @Test("请求解析：对象、通知、显式 null id")
    func requestParsing() throws {
        let request = try MCPRequest.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"x"}}"#.utf8))
        #expect(request.id == .int(7))
        #expect(request.method == "tools/call")
        #expect(!request.isNotification)

        let notification = try MCPRequest.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notification.isNotification)

        let nullID = try MCPRequest.parse(Data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#.utf8))
        #expect(nullID.id == .null)
        #expect(!nullID.isNotification)
    }

    @Test("请求解析：坏消息报错")
    func requestParseFailures() {
        #expect(throws: MCPProtocolError.parse) {
            try MCPRequest.parse(Data("not json".utf8))
        }
        #expect(throws: MCPProtocolError.invalidRequest) {
            try MCPRequest.parse(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        }
        #expect(throws: MCPProtocolError.invalidRequest) {
            try MCPRequest.parse(Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8))
        }
    }

    @Test("协议版本协商：认识的版本原样回显，不认识的回落")
    func versionNegotiation() {
        #expect(MCPProtocolVersion.negotiate("2025-03-26") == "2025-03-26")
        #expect(MCPProtocolVersion.negotiate("1999-01-01") == MCPProtocolVersion.current)
        #expect(MCPProtocolVersion.negotiate(nil) == MCPProtocolVersion.current)
    }

    @Test("响应序列化：成功与错误")
    func responseSerialization() throws {
        let success = MCPResponse.success(.int(1), .object(["ok": .bool(true)]))
        let successObject = try MCPJSON.parse(success.serialized())
        #expect(successObject.objectValue?["id"] == .int(1))
        #expect(successObject.objectValue?["result"]?.objectValue?["ok"] == .bool(true))
        #expect(successObject.objectValue?["error"] == nil)

        let failure = MCPResponse.failure(.string("a"), .invalidParams("缺少参数"))
        let failureObject = try MCPJSON.parse(failure.serialized())
        #expect(failureObject.objectValue?["error"]?.objectValue?["code"] == .int(-32602))
        #expect(failureObject.objectValue?["error"]?.objectValue?["message"] == .string("缺少参数"))
    }

    @Test("MCPJSON：NSNumber 布尔与整数不混淆")
    func jsonNumberBooleanDiscrimination() throws {
        let value = try MCPJSON.parse(Data(#"{"a":true,"b":1,"c":1.5,"d":"s"}"#.utf8))
        #expect(value.objectValue?["a"] == .bool(true))
        #expect(value.objectValue?["b"] == .int(1))
        #expect(value.objectValue?["c"] == .double(1.5))
        #expect(value.objectValue?["d"] == .string("s"))
    }
}
