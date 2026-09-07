import Foundation
import JellyMCP
import Testing

@Suite("MCP 回环 HTTP 传输")
@MainActor
struct MCPHTTPTransportTests {
    private let token = "test-token-1234"

    private func makeServer() async throws -> (MCPHTTPServer, UInt16) {
        let core = makeTestCore(gateway: MockGateway())
        let server = MCPHTTPServer(core: core, token: token)
        let port = try server.start(preferredPort: 0)
        return (server, port)
    }

    private func post(
        _ port: UInt16,
        body: Data,
        authorization: String? = "Bearer test-token-1234",
        method: String = "POST"
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    @Test("initialize 往返：200 + JSON 响应")
    func initializeRoundTrip() async throws {
        let (server, port) = try await makeServer()
        defer { server.stop() }
        let (data, status) = try await post(
            port,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#.utf8)
        )
        #expect(status == 200)
        let parsed = try MCPJSON.parse(data)
        let result = try #require(parsed.objectValue?["result"]?.objectValue)
        #expect(result["protocolVersion"] == .string("2025-03-26"))
        #expect(result["serverInfo"]?.objectValue?["name"] == .string("jelly-test"))
    }

    @Test("令牌错误返回 401，未带令牌也返回 401")
    func unauthorized() async throws {
        let (server, port) = try await makeServer()
        defer { server.stop() }
        let wrongToken = try await post(
            port,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8),
            authorization: "Bearer wrong"
        )
        #expect(wrongToken.1 == 401)

        let noToken = try await post(
            port,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8),
            authorization: nil
        )
        #expect(noToken.1 == 401)
    }

    @Test("通知返回 202 且无响应体；GET 返回 405")
    func notificationAndMethodGuard() async throws {
        let (server, port) = try await makeServer()
        defer { server.stop() }

        let (data, status) = try await post(
            port,
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        #expect(status == 202)
        #expect(data.isEmpty)

        var getRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        getRequest.httpMethod = "GET"
        getRequest.setValue("Bearer test-token-1234", forHTTPHeaderField: "Authorization")
        let (_, getResponse) = try await URLSession.shared.data(for: getRequest)
        #expect((getResponse as? HTTPURLResponse)?.statusCode == 405)
    }

    @Test("重复 start 返回同一端口，stop 后端口可复用")
    func startStop() async throws {
        let (server, port) = try await makeServer()
        #expect(try server.start(preferredPort: 0) == port)
        server.stop()
        #expect(server.port == nil)
    }
}
