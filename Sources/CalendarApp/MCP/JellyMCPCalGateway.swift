import Foundation
import JellyMCP
import WorkspaceDomain

/// Bridges the MCP toolbox to the live workspace. All commands enter the same
/// main-actor FIFO the UI uses, so MCP mutations and app mutations serialize,
/// persist identically, and share one undo stack.
@MainActor
final class JellyMCPCalGateway: JellyMCPGateway {
    private let store: WorkspaceStore

    init(store: WorkspaceStore) {
        self.store = store
    }

    func currentState() -> WorkspaceState {
        store.state
    }

    func send(_ command: WorkspaceCommand, undoLabel: String?) async throws -> MCPMutationResult {
        let outcome = try await store.sendWorkspace(command, undoLabel: undoLabel)
        return Self.map(outcome)
    }

    func undo() async throws -> MCPMutationResult {
        let outcome: WorkspaceTransactionOutcome
        do {
            outcome = try await store.undo()
        } catch let error as WorkspaceStoreError {
            switch error {
            case .nothingToUndo:
                throw MCPGatewayError(code: "nothing_to_undo", message: "没有可撤销的操作。")
            case .nothingToRedo, .frozen:
                throw MCPGatewayError(code: "store_unavailable", message: "Jelly 工作区当前不可用。")
            }
        }
        return Self.map(outcome)
    }

    private static func map(_ outcome: WorkspaceTransactionOutcome) -> MCPMutationResult {
        switch outcome {
        case let .committed(receipt, _):
            return MCPMutationResult(status: .committed(revision: receipt.workspaceRevision))
        case .draftAlreadyPersisted, .restored:
            return MCPMutationResult(status: .committed(revision: nil))
        case let .noChange(reason, _):
            return MCPMutationResult(status: .noChange(reason: describe(reason)))
        case let .conflict(conflict):
            return MCPMutationResult(status: .conflict(description: describe(conflict)))
        case .draftSuperseded:
            return MCPMutationResult(status: .conflict(description: "笔记草稿已被更新的草稿取代。"))
        case .commitPending, .notCommitted:
            return MCPMutationResult(
                status: .uncertain(description: "命令尚未确认提交，请打开「恢复与备份」窗口查看待处理事务。")
            )
        case .externalSourceChanged:
            return MCPMutationResult(
                status: .conflict(description: "主文档在 Jelly 之外被修改，需要先处理外部变更。")
            )
        case let .persistenceBlocked(_, reason, _):
            return MCPMutationResult(status: .persistenceBlocked(description: describe(reason)))
        }
    }

    private static func describe(_ reason: WorkspaceNoChangeReason) -> String {
        switch reason {
        case .identical: "提交内容与当前状态完全相同"
        case .cancelled: "命令被取消"
        case .staleLegacyPreview: "旧版预览数据已过期"
        case .staleMetadata: "元数据已过期"
        case .staleDeleteAuthorization: "删除授权已过期"
        case .staleConsistencyPreview: "一致性预览已过期"
        case .inspirationAlreadyConverted: "该灵感已转换为笔记"
        case .staleMaterialDigestRun, .staleMaterialDigestSource: "材料提炼任务状态已过期"
        case .materialDigestNotRunning: "材料提炼任务未在运行"
        case .materialDigestAlreadyRunning: "材料提炼任务已在运行"
        case .materialDigestAlreadyWritten: "材料提炼结果已写入笔记"
        case .staleMaterialDigestNote: "目标笔记已过期"
        }
    }

    private static func describe(_ conflict: WorkspaceConflict) -> String {
        switch conflict {
        case let .noteDraft(draft):
            "笔记草稿冲突：当前版本 \(draft.currentRevision)，提交基于过期版本。"
        case let .noteMissing(noteID):
            "笔记不存在：\(noteID.rawValue.uuidString)"
        case .decomposition:
            "任务分解状态冲突。"
        }
    }

    private static func describe(_ reason: WorkspacePersistenceBlockReason) -> String {
        switch reason {
        case .unreadablePrimary: "主文档不可读。"
        case .opaqueInvalidPrimary: "主文档无法解析，需要从恢复中心处理。"
        case .loadFailed: "工作区加载失败。"
        }
    }
}
