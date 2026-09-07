import Foundation

/// MCP protocol versions this server can speak. Negotiation echoes the client's
/// version when it is one we know, otherwise falls back to the newest.
public enum MCPProtocolVersion {
    public static let current = "2025-06-18"

    static let known: Set<String> = [
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]

    public static func negotiate(_ requested: String?) -> String {
        guard let requested, known.contains(requested) else { return current }
        return requested
    }
}

/// One incoming JSON-RPC message. `id == nil` marks a notification, which must
/// never produce a response frame.
public struct MCPRequest: Equatable, Sendable {
    public let id: MCPJSON?
    public let method: String
    public let params: MCPJSON?

    public var isNotification: Bool { id == nil }

    public init(id: MCPJSON?, method: String, params: MCPJSON?) {
        self.id = id
        self.method = method
        self.params = params
    }

    public static func parse(_ data: Data) throws -> MCPRequest {
        let value: MCPJSON
        do {
            value = try MCPJSON.parse(data)
        } catch {
            throw MCPProtocolError.parse
        }
        guard let object = value.objectValue else {
            throw MCPProtocolError.invalidRequest
        }
        if let jsonrpc = object["jsonrpc"], jsonrpc != .string("2.0") {
            throw MCPProtocolError.invalidRequest
        }
        guard let method = object["method"]?.stringValue else {
            throw MCPProtocolError.invalidRequest
        }
        // Absent id = notification; an explicit JSON null id is still a request.
        let id = object.keys.contains("id") ? (object["id"] ?? .null) : nil
        return MCPRequest(id: id, method: method, params: object["params"])
    }
}

public enum MCPProtocolError: Error, Equatable, Sendable {
    case parse
    case invalidRequest
}

public struct MCPErrorDetail: Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: MCPJSON?

    public init(code: Int, message: String, data: MCPJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parse(_ message: String) -> MCPErrorDetail {
        MCPErrorDetail(code: -32700, message: message)
    }

    public static func invalidRequest(_ message: String) -> MCPErrorDetail {
        MCPErrorDetail(code: -32600, message: message)
    }

    public static func methodNotFound(_ message: String) -> MCPErrorDetail {
        MCPErrorDetail(code: -32601, message: message)
    }

    public static func invalidParams(_ message: String) -> MCPErrorDetail {
        MCPErrorDetail(code: -32602, message: message)
    }

    public static func internalError(_ message: String) -> MCPErrorDetail {
        MCPErrorDetail(code: -32603, message: message)
    }

    var json: MCPJSON {
        var payload: [String: MCPJSON] = [
            "code": .int(Int64(code)),
            "message": .string(message)
        ]
        if let data {
            payload["data"] = data
        }
        return .object(payload)
    }
}

public struct MCPResponse: Equatable, Sendable {
    public let id: MCPJSON
    public let result: MCPJSON?
    public let error: MCPErrorDetail?

    public init(id: MCPJSON, result: MCPJSON?, error: MCPErrorDetail?) {
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(_ id: MCPJSON, _ result: MCPJSON) -> MCPResponse {
        MCPResponse(id: id, result: result, error: nil)
    }

    public static func failure(_ id: MCPJSON, _ error: MCPErrorDetail) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: error)
    }

    public func serialized() -> Data {
        var payload: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "id": id
        ]
        if let error {
            payload["error"] = error.json
        } else {
            payload["result"] = result ?? .object([:])
        }
        return MCPJSON.object(payload).serialized()
    }
}
