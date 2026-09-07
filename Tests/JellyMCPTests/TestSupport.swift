import CalendarDomain
import Foundation
import JellyMCP
import Testing
import WorkspaceDomain

/// Applies workspace commands through the real public reducer so tool tests
/// exercise genuine domain semantics without the app store.
@MainActor
final class MockGateway: JellyMCPGateway {
    private(set) var state: WorkspaceState
    private var history: [WorkspaceState] = []
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    init(calendar: CalendarState = CalendarState.empty(
        uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
        now: .distantPast
    )) {
        state = WorkspaceState.empty(calendar: calendar)
    }

    func currentState() -> WorkspaceState {
        state
    }

    func send(_ command: WorkspaceCommand, undoLabel: String?) async throws -> MCPMutationResult {
        history.append(state)
        let reduction = try WorkspaceReducer.reduce(state, command: command, now: now)
        switch reduction {
        case let .changed(change):
            state = change.state
            return MCPMutationResult(status: .committed(revision: change.state.revision))
        case let .noChange(reason):
            return MCPMutationResult(status: .noChange(reason: String(describing: reason)))
        case let .conflict(conflict):
            return MCPMutationResult(status: .conflict(description: String(describing: conflict)))
        }
    }

    func undo() async throws -> MCPMutationResult {
        guard let previous = history.popLast() else {
            throw MCPGatewayError(code: "nothing_to_undo", message: "没有可撤销的操作。")
        }
        state = previous
        return MCPMutationResult(status: .committed(revision: nil))
    }
}

@MainActor
func makeTestCore(gateway: MockGateway) -> MCPServerCore {
    MCPServerCore(
        identity: MCPServerIdentity(name: "jelly-test", version: "0"),
        tools: JellyMCPToolbox(gateway: gateway)
    )
}

/// Sends one raw frame through the core and returns the parsed response object.
@MainActor
func handleAndParse(_ core: MCPServerCore, _ request: MCPJSON) async throws -> [String: MCPJSON] {
    let data = try #require(await core.handle(request.serialized()))
    let value = try MCPJSON.parse(data)
    let object = try #require(value.objectValue)
    return object
}
