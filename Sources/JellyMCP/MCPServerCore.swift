import Foundation

public struct MCPServerIdentity: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPToolDefinition: Equatable, Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: MCPJSON

    public init(name: String, title: String, description: String, inputSchema: MCPJSON) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    var json: MCPJSON {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

public struct MCPCallResult: Equatable, Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func success(_ payload: MCPJSON) -> MCPCallResult {
        MCPCallResult(text: String(data: payload.serialized(), encoding: .utf8) ?? "{}")
    }

    public static func failure(_ payload: MCPJSON) -> MCPCallResult {
        MCPCallResult(text: String(data: payload.serialized(), encoding: .utf8) ?? "{}", isError: true)
    }

    var contentJSON: MCPJSON {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "isError": .bool(isError)
        ])
    }
}

/// Anything that can answer `tools/list` / `tools/call`. The MCP protocol layer
/// never sees domain types; the toolbox adapts the Jelly gateway.
public protocol MCPToolHandler: Sendable {
    func definitions() -> [MCPToolDefinition]
    func call(name: String, arguments: MCPJSON) async -> MCPCallResult
}

/// Transport-agnostic MCP server core: JSON-RPC dispatch for a tools-only
/// server. Transports (stdio bridge, loopback HTTP) feed it raw message bytes
/// and ship back the serialized responses.
public final class MCPServerCore: Sendable {
    public let identity: MCPServerIdentity
    private let tools: any MCPToolHandler

    public init(identity: MCPServerIdentity, tools: any MCPToolHandler) {
        self.identity = identity
        self.tools = tools
    }

    /// Handles one raw wire frame (object or batch array). Returns the bytes to
    /// send back, or nil when the frame contained only notifications.
    public func handle(_ data: Data) async -> Data? {
        let value: MCPJSON
        do {
            value = try MCPJSON.parse(data)
        } catch {
            return MCPResponse
                .failure(.null, .parse("无法解析 JSON-RPC 消息。"))
                .serialized()
        }

        switch value {
        case let .array(messages):
            let responses = await respondToAll(messages)
            guard !responses.isEmpty else { return nil }
            let batch = MCPJSON.array(responses)
            return String(data: batch.serialized(), encoding: .utf8).map { Data($0.utf8) }
        case .object:
            return await respondTo(value)
        default:
            return MCPResponse
                .failure(.null, .invalidRequest("JSON-RPC 消息必须是对象或数组。"))
                .serialized()
        }
    }

    private func respondToAll(_ messages: [MCPJSON]) async -> [MCPJSON] {
        var responses: [MCPJSON] = []
        for message in messages {
            guard message.objectValue != nil else { continue }
            if let responseData = await respondTo(message),
               let parsed = try? MCPJSON.parse(responseData) {
                responses.append(parsed)
            }
        }
        return responses
    }

    /// Returns the serialized response bytes, or nil for notifications.
    public func respondTo(_ value: MCPJSON) async -> Data? {
        let request: MCPRequest
        do {
            request = try MCPRequest.parse(value.jsonData())
        } catch {
            let id = value.objectValue?["id"] ?? .null
            let detail: MCPErrorDetail = (error as? MCPProtocolError) == .parse
                ? .parse("无法解析 JSON-RPC 消息。")
                : .invalidRequest("JSON-RPC 请求缺少 method 字段或格式不正确。")
            return MCPResponse.failure(id, detail).serialized()
        }

        if request.method.hasPrefix("notifications/") {
            return nil
        }

        let id = request.id ?? .null
        let response: MCPResponse
        switch request.method {
        case "initialize":
            response = handleInitialize(request, id: id)
        case "ping":
            response = .success(id, .object([:]))
        case "tools/list":
            response = handleToolsList(id: id)
        case "tools/call":
            response = await handleToolsCall(request, id: id)
        default:
            response = .failure(id, .methodNotFound("不支持的方法：\(request.method)"))
        }
        return response.serialized()
    }

    private func handleInitialize(_ request: MCPRequest, id: MCPJSON) -> MCPResponse {
        let requested = request.params?.objectValue?["protocolVersion"]?.stringValue
        let version = MCPProtocolVersion.negotiate(requested)
        let result = MCPJSON.object([
            "protocolVersion": .string(version),
            "capabilities": .object([
                "tools": .object([
                    "listChanged": .bool(false)
                ])
            ]),
            "serverInfo": .object([
                "name": .string(identity.name),
                "version": .string(identity.version)
            ])
        ])
        return .success(id, result)
    }

    private func handleToolsList(id: MCPJSON) -> MCPResponse {
        let tools = tools.definitions().map(\.json)
        return .success(id, .object([
            "tools": .array(tools)
        ]))
    }

    private func handleToolsCall(_ request: MCPRequest, id: MCPJSON) async -> MCPResponse {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            return .failure(id, .invalidParams("tools/call 缺少 name 参数。"))
        }
        let known = tools.definitions().map(\.name)
        guard known.contains(name) else {
            return .failure(id, .invalidParams("未知工具：\(name)"))
        }
        let arguments = params["arguments"]?.objectValue.map { MCPJSON.object($0) } ?? .object([:])
        let result = await tools.call(name: name, arguments: arguments)
        return .success(id, result.contentJSON)
    }
}
