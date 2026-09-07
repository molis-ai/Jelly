import Foundation

// jelly-mcp: a stdio ⇄ HTTP bridge in front of Jelly's in-app MCP endpoint.
//
// MCP clients that only spawn stdio servers (Claude Desktop's classic
// `mcpServers` config) launch this binary; every JSON-RPC line on stdin is
// forwarded verbatim to the app's loopback HTTP endpoint and the response line
// is written back to stdout. The app owns the actual MCP protocol and the
// WorkspaceStore; this process stays stateless.
//
// Endpoint discovery order:
//   1. JELLY_MCP_URL (+ optional JELLY_MCP_TOKEN)
//   2. JELLY_MCP_PORT (implies 127.0.0.1, token from JELLY_MCP_TOKEN)
//   3. `mcp-server.json` inside the Jelly data directory (daily, then Preview),
//      override the directory with JELLY_MCP_DATA_DIR.
//
// When the app is not reachable, the bridge tries `open -b` once to launch
// Jelly, then polls briefly before giving up (requests keep failing with a
// clear JSON-RPC error either way).

@main
struct JellyMCPBridgeMain {
    static func main() async {
        await JellyMCPBridge().run()
    }
}

struct BridgeConfiguration: Sendable {
    let endpointURL: URL
    let token: String?
    let launchBundleID: String?
}

enum MCPBridgeID: Sendable {
    case null
    case number(NSNumber)
    case string(String)

    var jsonLiteral: String {
        switch self {
        case .null: "null"
        case let .number(number): number.stringValue
        case let .string(string): JellyMCPBridge.jsonEscaped(string)
        }
    }
}

/// All mutable state is touched only from the single `run()` task; Sendable is
/// safe to assume unchecked.
final class JellyMCPBridge: @unchecked Sendable {
    private static let endpointFileName = "mcp-server.json"
    private static let defaultLaunchBundleID = "com.oreal.personalcalendar"
    private static let pingFrame = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
    private static let missingConfigurationMessage =
        "未找到 Jelly MCP 端点配置：请启动 Jelly，并在 设置 → MCP 服务器 中开启。"

    private let session: URLSession
    private let configuration: BridgeConfiguration?
    private var attemptedLaunch = false

    init() {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 120
        session = URLSession(configuration: sessionConfiguration)
        configuration = Self.resolveConfiguration()
        if configuration == nil {
            Self.log("未找到 Jelly MCP 端点配置：请启动 Jelly，并在 设置 → MCP 服务器 中开启。")
        }
    }

    func run() async {
        Self.log("jelly-mcp 桥已启动")
        await ensureEndpointReachable()
        for await line in stdinLines() {
            await forward(line: line)
        }
    }

    // MARK: Stdio loop

    private func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    private func forward(line rawLine: String) async {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        let requestID = Self.requestID(fromLine: line)
        guard let configuration else {
            writeError(id: requestID ?? .null, message: Self.missingConfigurationMessage)
            return
        }

        do {
            let (data, statusCode) = try await post(configuration, body: Data(line.utf8), timeout: 60)
            switch statusCode {
            case 200:
                guard !data.isEmpty else { return }
                writeLine(Data(data))
            case 202, 204:
                // Notification accepted; nothing to emit on stdout.
                return
            default:
                writeError(
                    id: requestID ?? .null,
                    message: "Jelly MCP 端点返回 HTTP \(statusCode)。"
                )
            }
        } catch let error as URLError where error.isConnectivityFailure {
            if !attemptedLaunch, let bundleID = configuration.launchBundleID {
                attemptedLaunch = true
                await launchApp(bundleID: bundleID)
                if await pollUntilReachable(configuration, attempts: 16, intervalNanos: 500_000_000) {
                    await forward(line: rawLine)
                    return
                }
            }
            // Notifications expect no response frame, so stay silent on stdout.
            guard requestID != nil else { return }
            writeError(
                id: requestID!,
                message: "无法连接 Jelly 的 MCP 端点（\(configuration.endpointURL.absoluteString)）。请确认 Jelly 已启动且 MCP 服务器已开启。"
            )
        } catch {
            guard requestID != nil else { return }
            writeError(id: requestID!, message: "请求 Jelly MCP 端点失败：\(error.localizedDescription)")
        }
    }

    // MARK: Reachability / app launch

    private func ensureEndpointReachable() async {
        guard let configuration else { return }
        if await isEndpointReachable(configuration) { return }
        if !attemptedLaunch, let bundleID = configuration.launchBundleID {
            attemptedLaunch = true
            await launchApp(bundleID: bundleID)
            _ = await pollUntilReachable(configuration, attempts: 16, intervalNanos: 500_000_000)
        }
    }

    private func isEndpointReachable(_ configuration: BridgeConfiguration) async -> Bool {
        guard let (_, statusCode) = try? await post(configuration, body: Self.pingFrame, timeout: 5) else {
            return false
        }
        return statusCode == 200
    }

    private func pollUntilReachable(
        _ configuration: BridgeConfiguration,
        attempts: Int,
        intervalNanos: UInt64
    ) async -> Bool {
        for _ in 0..<max(1, attempts) {
            if await isEndpointReachable(configuration) { return true }
            try? await Task.sleep(nanoseconds: intervalNanos)
        }
        return false
    }

    private func post(_ configuration: BridgeConfiguration, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, statusCode)
    }

    private func launchApp(bundleID: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gb", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.log("自动启动 Jelly 失败：\(error.localizedDescription)")
        }
    }

    // MARK: Configuration discovery

    static func resolveConfiguration() -> BridgeConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["JELLY_MCP_URL"], let url = URL(string: raw), url.scheme != nil {
            return BridgeConfiguration(
                endpointURL: url,
                token: environment["JELLY_MCP_TOKEN"],
                launchBundleID: environment["JELLY_MCP_LAUNCH_BUNDLE_ID"] ?? defaultLaunchBundleID
            )
        }
        if let raw = environment["JELLY_MCP_PORT"], let port = Int(raw), (1...65535).contains(port) {
            return BridgeConfiguration(
                endpointURL: URL(string: "http://127.0.0.1:\(port)/mcp")!,
                token: environment["JELLY_MCP_TOKEN"],
                launchBundleID: environment["JELLY_MCP_LAUNCH_BUNDLE_ID"] ?? defaultLaunchBundleID
            )
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let profileDirectories = [
            support?.appendingPathComponent("PersonalCalendar", isDirectory: true),
            support?.appendingPathComponent("PersonalCalendarPreview", isDirectory: true)
        ].compactMap { $0 }
        let directories: [URL]
        if let override = environment["JELLY_MCP_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            directories = [URL(fileURLWithPath: override, isDirectory: true)]
        } else {
            directories = profileDirectories
        }

        for directory in directories {
            let fileURL = directory.appendingPathComponent(endpointFileName)
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let port = object["port"] as? Int, (1...65535).contains(port) else {
                continue
            }
            // Only auto-launch on connection failure when the endpoint file came
            // from a well-known profile directory, not an arbitrary path.
            let knownProfile = environment["JELLY_MCP_DATA_DIR"] == nil
            let token = (object["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? environment["JELLY_MCP_TOKEN"]
            return BridgeConfiguration(
                endpointURL: URL(string: "http://127.0.0.1:\(port)/mcp")!,
                token: token,
                launchBundleID: knownProfile ? defaultLaunchBundleID : nil
            )
        }
        return nil
    }

    // MARK: Parsing / output helpers

    /// Extracts the JSON-RPC id from a raw line. Returns nil for notifications
    /// (no `id` member) and for lines that are not requests at all.
    static func requestID(fromLine line: String) -> MCPBridgeID? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] != nil else {
            return nil
        }
        switch object["id"] {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .number(number)
            }
            return .number(number)
        case let string as String:
            return .string(string)
        case .some(let other):
            return .string(String(describing: other))
        case nil:
            return nil // notification: no response expected
        }
    }

    private func writeLine(_ data: Data) {
        FileHandle.standardOutput.write(data)
        if data.last != 0x0A {
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func writeError(id: MCPBridgeID, message: String) {
        let payload =
            "{\"jsonrpc\":\"2.0\",\"id\":\(id.jsonLiteral),\"error\":{\"code\":-32000,\"message\":\(Self.jsonEscaped(message))}}"
        writeLine(Data(payload.utf8))
    }

    /// JSON-encodes a bare string by round-tripping through a one-element array.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[jelly-mcp] \(message)\n".utf8))
    }
}

extension URLError {
    var isConnectivityFailure: Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .cannotLoadFromNetwork,
             .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .dnsLookupFailed, .resourceUnavailable:
            true
        default:
            false
        }
    }
}
