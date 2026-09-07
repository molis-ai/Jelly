import AppKit
import Foundation
import JellyMCP
import Observation
import Security

/// Owns the loopback MCP HTTP server for the running app: starts it after the
/// workspace loads, publishes status for the settings pane, and maintains the
/// `mcp-server.json` endpoint file the stdio bridge and users read.
@MainActor
@Observable
final class MCPServiceController {
    static let enabledKey = "mcp.server.enabled"
    static let preferredPortKey = "mcp.server.port"
    static let defaultPreferredPort: UInt16 = 8787

    private let gateway: any JellyMCPGateway
    private let endpointFileURL: URL
    private let defaults: UserDefaults
    private var server: MCPHTTPServer?
    private var terminationObserver: NSObjectProtocol?

    private(set) var isRunning = false
    private(set) var port: UInt16?
    private(set) var token: String?
    private(set) var lastError: String?

    init(
        gateway: any JellyMCPGateway,
        endpointFileURL: URL,
        defaults: UserDefaults = .standard
    ) {
        self.gateway = gateway
        self.endpointFileURL = endpointFileURL
        self.defaults = defaults
    }

    // MARK: Preferences

    var isEnabled: Bool {
        get {
            defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue {
                startIfNeeded()
            } else {
                stop()
            }
        }
    }

    var preferredPort: UInt16 {
        let stored = defaults.integer(forKey: Self.preferredPortKey)
        guard stored > 0, stored <= Int(UInt16.max) else { return Self.defaultPreferredPort }
        return UInt16(stored)
    }

    // MARK: Client configuration snippets

    var endpointDescription: String? {
        guard let port else { return nil }
        return "http://127.0.0.1:\(port)/mcp"
    }

    var claudeCodeCommand: String? {
        guard let endpointDescription else { return nil }
        return "claude mcp add --transport http jelly \(endpointDescription) --header \"Authorization: Bearer \(token ?? "")\""
    }

    var desktopJSONConfig: String? {
        guard let endpointDescription else { return nil }
        let prettyToken = token ?? "<token>"
        return """
        {
          "mcpServers": {
            "jelly": {
              "command": "/Applications/Jelly.app/Contents/MacOS/jelly-mcp",
              "env": {
                "JELLY_MCP_URL": "\(endpointDescription)",
                "JELLY_MCP_TOKEN": "\(prettyToken)"
              }
            }
          }
        }
        """
    }

    // MARK: Lifecycle

    func startIfNeeded() {
        guard isEnabled, !isRunning else { return }
        start()
    }

    func stop() {
        guard isRunning else { return }
        server?.stop()
        server = nil
        isRunning = false
        port = nil
        token = nil
        removeEndpointFile()
    }

    private func start() {
        let token = Self.generateToken()
        let core = MCPServerCore(
            identity: MCPServerIdentity(name: "jelly", version: Self.appVersion),
            tools: JellyMCPToolbox(gateway: gateway)
        )
        let server = MCPHTTPServer(core: core, token: token)
        do {
            let port = try server.start(preferredPort: preferredPort)
            self.server = server
            self.port = port
            self.token = token
            isRunning = true
            lastError = nil
            try writeEndpointFile(port: port, token: token)
            observeTermination()
            Self.log("已启动：127.0.0.1:\(port)")
        } catch {
            self.server = nil
            lastError = String(describing: error)
            Self.log("启动失败：\(error)")
        }
    }

    private func writeEndpointFile(port: UInt16, token: String) throws {
        let directory = endpointFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "server": "jelly",
            "port": Int(port),
            "token": token
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: endpointFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFileURL.path)
    }

    private func removeEndpointFile() {
        try? FileManager.default.removeItem(at: endpointFileURL)
    }

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    // MARK: Helpers

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[jelly-mcp] \(message)\n".utf8))
    }
}
