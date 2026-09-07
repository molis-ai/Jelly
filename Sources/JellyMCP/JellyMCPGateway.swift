import Foundation
import WorkspaceDomain

/// Normalized result of one gateway mutation. The gateway implementation (in
/// the app target) maps `WorkspaceTransactionOutcome` into these cases; the MCP
/// layer only ever sees them.
public struct MCPMutationResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Persisted and published; optional workspace revision of the commit.
        case committed(revision: Int64?)
        /// Reducer accepted the command but the state did not change.
        case noChange(reason: String)
        /// Reducer rejected the command (e.g. a stale note draft revision).
        case conflict(description: String)
        /// The command is real but persistence could not complete; data stays
        /// in the recovery journal until the app resolves it.
        case persistenceBlocked(description: String)
        /// Neither committed nor definitively rejected; recovery center owns it.
        case uncertain(description: String)
    }

    public let status: Status

    public init(status: Status) {
        self.status = status
    }

    public var isCommitted: Bool {
        if case .committed = status { return true }
        return false
    }
}

/// Thrown by gateway implementations for store-level failures that are not
/// outcomes (e.g. undo with an empty stack).
public struct MCPGatewayError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The seam between the MCP toolbox and the running app. All methods are main
/// actor isolated because the app store is; transports await across.
@MainActor
public protocol JellyMCPGateway: Sendable {
    /// Consistent value snapshot of the current workspace. Tools run read-only
    /// projections (timeline, search) over it locally.
    func currentState() -> WorkspaceState

    /// Sends one workspace command through the same transaction queue the UI
    /// uses. The label surfaces as the in-app undo toast text.
    func send(_ command: WorkspaceCommand, undoLabel: String?) async throws -> MCPMutationResult

    func undo() async throws -> MCPMutationResult
}
