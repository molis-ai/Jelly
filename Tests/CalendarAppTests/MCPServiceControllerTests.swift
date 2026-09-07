import CalendarDomain
import Foundation
import JellyMCP
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MCP 服务控制器（真实 HTTP 服务器 + 端点文件）")
@MainActor
struct MCPServiceControllerTests {
    private final class PassthroughGateway: JellyMCPGateway {
        private let store: WorkspaceStore

        init(store: WorkspaceStore) {
            self.store = store
        }

        func currentState() -> WorkspaceState {
            store.state
        }

        func send(_ command: WorkspaceCommand, undoLabel: String?) async throws -> MCPMutationResult {
            MCPMutationResult(status: .committed(revision: nil))
        }

        func undo() async throws -> MCPMutationResult {
            MCPMutationResult(status: .committed(revision: nil))
        }
    }

    private func makeController(
        directory: URL,
        defaults: UserDefaults
    ) async throws -> (MCPServiceController, WorkspaceStore) {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let gateway = PassthroughGateway(store: store)
        let controller = MCPServiceController(
            gateway: gateway,
            endpointFileURL: directory.appendingPathComponent("mcp-server.json"),
            defaults: defaults
        )
        return (controller, store)
    }

    @Test("startIfNeeded 启动监听并写出端点文件；stop 删除文件")
    func startStopLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-mcp-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "jelly-mcp-controller-tests-\(UUID().uuidString)")!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
        }

        let (controller, store) = try await makeController(directory: directory, defaults: defaults)
        #expect(controller.isEnabled)

        controller.startIfNeeded()
        #expect(controller.isRunning)
        let port = try #require(controller.port)
        let token = try #require(controller.token)
        #expect(port > 0)

        let endpointFile = directory.appendingPathComponent("mcp-server.json")
        let fileData = try #require(FileManager.default.contents(atPath: endpointFile.path))
        let object = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        #expect(object["port"] as? Int == Int(port))
        #expect(object["token"] as? String == token)

        // The advertised endpoint actually answers initialize.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let parsed = try MCPJSON.parse(data)
        #expect(try #require(parsed.objectValue?["result"]?.objectValue)["protocolVersion"] != nil)

        controller.stop()
        #expect(!controller.isRunning)
        #expect(controller.port == nil)
        #expect(FileManager.default.fileExists(atPath: endpointFile.path) == false)
        #expect(store.phase == .ready)
    }

    @Test("关闭开关后 startIfNeeded 不启动")
    func disabledDoesNotStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-mcp-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "jelly-mcp-controller-tests-\(UUID().uuidString)")!
        defaults.set(false, forKey: MCPServiceController.enabledKey)

        let (controller, _) = try await makeController(directory: directory, defaults: defaults)
        controller.startIfNeeded()
        #expect(!controller.isRunning)
        #expect(controller.port == nil)

        controller.isEnabled = true
        #expect(controller.isRunning)
        controller.isEnabled = false
        #expect(!controller.isRunning)
    }
}
