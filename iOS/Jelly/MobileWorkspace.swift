import CalendarDomain
import CalendarPersistence
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
import WorkspaceDomain

/// The mobile shell uses the desktop transaction owner and document format.
/// This object only assembles sandbox services and presents their outcomes.
@MainActor
@Observable
final class MobileWorkspace {
    let store: WorkspaceStore
    let rootURL: URL
    let searchIndex: WorkspaceSearchIndex
    let mcp: MCPServiceController
    let ai: MobileAIServices
    let sync: WorkspaceSyncService

    var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var recoveryAction: WorkspaceRecoveryAction?
    private(set) var restorePreview: WorkspaceRestorePreview?

    private let rollbackDirectoryURL: URL
    @ObservationIgnored private var editorBarriers: [UUID: @MainActor () async -> Bool] = [:]

    var state: WorkspaceState { store.state }
    var isReady: Bool { store.phase == .ready }
    var canUndo: Bool { isReady && store.canUndo }
    var canRedo: Bool { isReady && store.canRedo }
    var canRestore: Bool {
        BackupRecoveryPolicy.allowsRestore(from: store.phase,
            journalReconciliationRequired: store.hasUnresolvedJournalReconciliation)
    }
    var canExportBackup: Bool { BackupRecoveryPolicy.allowsReadOnlyBackup(from: store.phase) }
    var recoveryActions: [BackupRecoveryAction] {
        BackupRecoveryPolicy.actions(for: store.phase, rawRecoveryAvailable: store.hasRawRecoverySource)
    }

    /// `rootURL` is injectable for isolated tests. Production resolves the
    /// application's own sandbox; it never locates desktop Jelly's database.
    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        let requestedRoot: URL
        if let rootURL {
            guard rootURL.isFileURL else { throw MobileWorkspaceError.invalidDirectory }
            requestedRoot = rootURL
        } else {
            requestedRoot = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Jelly", isDirectory: true)
        }
        try fileManager.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        let resolvedRoot = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedRoot.path != "/" else { throw MobileWorkspaceError.invalidDirectory }
        self.rootURL = resolvedRoot
        rollbackDirectoryURL = resolvedRoot.appendingPathComponent("restore-rollbacks", isDirectory: true)

        let empty = WorkspaceState.empty(calendar: .empty(uncategorizedID: UUID(), now: Date()))
        let repository = JSONWorkspaceRepository(
            documentURL: resolvedRoot.appendingPathComponent("calendar-v1.json"),
            seed: { empty },
            snapshotDirectoryURL: resolvedRoot.appendingPathComponent("calendar-v1.recovery-snapshots", isDirectory: true),
            recoveryManifestURL: resolvedRoot.appendingPathComponent("calendar-v1.recovery-manifest.json")
        )
        let journal = DraftJournalRepository(
            fileURL: resolvedRoot.appendingPathComponent("calendar-v1.draft-journal.json")
        )
        store = WorkspaceStore(initialState: empty, repository: repository, journal: journal)
        searchIndex = WorkspaceSearchIndex(fileURL: resolvedRoot.appendingPathComponent("workspace-search-v1.json"))
        mcp = MCPServiceController(
            gateway: JellyMCPCalGateway(store: store),
            endpointFileURL: resolvedRoot.appendingPathComponent("mcp-server.json")
        )
        ai = try MobileAIServices(store: store, rootURL: resolvedRoot)
        sync = WorkspaceSyncService(
            store: store,
            dataRoot: resolvedRoot,
            settings: SyncSettings(defaults: ai.settings.defaultsForCompanionSettings),
            deviceName: Self.deviceName
        )
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        "iPhone"
        #endif
    }

    // MARK: One workspace per process

    @ObservationIgnored private static var sharedInstance: MobileWorkspace?
    @ObservationIgnored private static var sharedLoad: Task<Void, Never>?

    /// The app window and App Intents (Siri, Shortcuts, share-sheet shortcuts)
    /// must write through the same store, never two stores on one file.
    static func shared() throws -> MobileWorkspace {
        if let sharedInstance { return sharedInstance }
        let workspace = try MobileWorkspace()
        sharedInstance = workspace
        return workspace
    }

    static func loadedShared() async throws -> MobileWorkspace {
        let workspace = try shared()
        if workspace.store.phase == .notLoaded {
            if sharedLoad == nil {
                sharedLoad = Task { @MainActor in await workspace.load() }
            }
            await sharedLoad?.value
        }
        return workspace
    }

    func load() async {
        guard await flushEditors() else { return }
        await store.load()
        if isReady { await ai.digest.reconcileInterruptedRuns() }
        presentCurrentPhase()
    }

    func registerEditorBarrier(id: UUID, flush: @escaping @MainActor () async -> Bool) {
        editorBarriers[id] = flush
    }

    func unregisterEditorBarrier(id: UUID) {
        editorBarriers.removeValue(forKey: id)
    }

    /// Snapshot the registrations before suspension: a disappearing editor may
    /// unregister while its last draft is still being protected and committed.
    func flushEditors() async -> Bool {
        let barriers = Array(editorBarriers.values)
        for flush in barriers {
            guard await flush() else {
                if errorMessage == nil { errorMessage = "笔记草稿尚未保存，请先处理编辑器中的保存提示。" }
                return false
            }
        }
        return true
    }

    @discardableResult
    func send(_ command: WorkspaceCommand, label: String? = nil) async -> Bool {
        await perform { try await self.store.sendWorkspace(command, undoLabel: label) }
    }

    @discardableResult
    func sendCalendar(_ command: CalendarCommand, label: String? = nil) async -> Bool {
        await send(.calendar(command), label: label)
    }

    @discardableResult
    func undo() async -> Bool {
        guard await flushEditors() else { return false }
        return await perform { try await self.store.undo() }
    }

    @discardableResult
    func redo() async -> Bool {
        guard await flushEditors() else { return false }
        return await perform { try await self.store.redo() }
    }

    @discardableResult
    func retryRecovery() async -> Bool {
        if let recoveryAction {
            return present(await WorkspaceMutationOutcomePresenter.retry(recoveryAction, in: store))
        }
        // A parked operation can originate from an editor or an AI service,
        // so its exact Store-issued ID must also be recoverable from the phase.
        do {
            switch store.phase {
            case let .parkedCommitUncertain(id):
                return present(WorkspaceMutationOutcomePresenter.presentation(for: try await store.retryPendingCommit(id)))
            case let .parkedJournalCleanup(identity, step):
                let status = await store.retryJournalCleanup(identity)
                let message = BackupRecoveryPolicy.message(for: status, completing: step)
                switch status {
                case .clean:
                    errorMessage = nil
                    statusMessage = message
                    return true
                case .cleanupPending:
                    errorMessage = message
                    return false
                }
            default: return false
            }
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func resolveDraftRecovery(_ token: DraftRecoveryToken, action: DraftRecoveryAction) async -> Bool {
        let completed = await perform {
            try await self.store.resolveDraftRecovery(token, action: action)
        }
        if completed { presentCurrentPhase() }
        return completed
    }

    /// Export is a verified copy. The share sheet can safely hand this URL to
    /// Files without giving the recipient access to the live database.
    func prepareBackupExport() async -> URL? {
        guard await flushEditors() else { return nil }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Jelly-Backup-Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("Jelly-\(UUID().uuidString).json")
            try await store.exportBackup(to: destination)
            errorMessage = nil
            statusMessage = "备份已准备好，可以保存到文件或分享。"
            return destination
        } catch {
            report(error)
            return nil
        }
    }

    /// Inspection reads and validates a snapshot only. The caller must show
    /// its contents before invoking `restore`; selecting a file never restores.
    @discardableResult
    func inspectBackup(at source: URL) async -> WorkspaceRestorePreview? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let preview = try await store.inspectRestoreSource(at: source)
            restorePreview = preview
            errorMessage = nil
            statusMessage = nil
            return preview
        } catch {
            restorePreview = nil
            report(error)
            return nil
        }
    }

    func cancelRestorePreview() { restorePreview = nil }

    /// Call after the user confirms the displayed preview. The repository
    /// preserves a rollback copy and verifies the replacement transaction.
    @discardableResult
    func restore(_ preview: WorkspaceRestorePreview) async -> Bool {
        guard await flushEditors() else { return false }
        do {
            let outcome = try await store.restore(preview, rollbackDirectoryURL: rollbackDirectoryURL)
            let restored = present(WorkspaceMutationOutcomePresenter.restorePresentation(for: outcome))
            if restored { restorePreview = nil }
            return restored
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func reloadExternalSource() async -> Bool {
        guard await flushEditors() else { return false }
        do {
            let result = try await store.reloadExternalSource()
            if case let .transaction(outcome) = result {
                return present(WorkspaceMutationOutcomePresenter.presentation(for: outcome))
            }
            presentCurrentPhase()
            return isReady
        } catch {
            report(error)
            return false
        }
    }

    func report(_ error: any Error) {
        errorMessage = WorkspaceMutationOutcomePresenter.message(for: error)
        statusMessage = nil
    }

    private func perform(_ operation: () async throws -> WorkspaceTransactionOutcome) async -> Bool {
        do {
            return present(WorkspaceMutationOutcomePresenter.presentation(for: try await operation()))
        } catch {
            report(error)
            return false
        }
    }

    private func present(_ presentation: WorkspaceMutationPresentation) -> Bool {
        recoveryAction = presentation.recoveryAction
        if presentation.allowsDismissal {
            errorMessage = nil
            statusMessage = presentation.message
        } else {
            errorMessage = presentation.message
            statusMessage = nil
        }
        return presentation.allowsDismissal
    }

    private func presentCurrentPhase() {
        switch store.phase {
        case .ready:
            errorMessage = nil
            statusMessage = nil
            recoveryAction = nil
        case .notLoaded, .loading, .mutating:
            break
        case .needsDraftRecovery:
            errorMessage = "发现尚未处理的笔记草稿，请先选择恢复方式。"
        case .needsRelationshipRepair:
            errorMessage = "发现需要修复的内容关联，请先检查恢复中心。"
        case .externalSourceChanged:
            errorMessage = "本地数据已变化，请重新载入并检查草稿。"
        case .opaquePrimaryLoadFailed:
            errorMessage = "本地数据无法解析，请保留原始文件并从备份恢复。"
        case .unreadablePrimaryLoadFailed:
            errorMessage = "本地数据暂时无法读取，请稍后重试。"
        case .loadFailed:
            errorMessage = "工作空间加载失败，请检查备份与恢复选项。"
        case .resolvingDraftRecovery, .reconcilingDraftRecovery,
             .parkedCommitUncertain, .parkedJournalCleanup:
            errorMessage = "保存或恢复尚未完成，请在恢复选项中继续处理。"
        }
    }
}

private enum MobileWorkspaceError: LocalizedError {
    case invalidDirectory

    var errorDescription: String? { "无法建立 Jelly 的本地数据目录。" }
}
