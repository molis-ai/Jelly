import CalendarDomain
import Foundation
import WorkspaceDomain

public struct WorkspaceLoadProvenance: Equatable, Sendable {
    public let sourceSchema: Int
    public let sourceBytesSHA256: String
    public let sourceByteCount: Int

    public init(sourceSchema: Int, sourceBytesSHA256: String, sourceByteCount: Int) {
        self.sourceSchema = sourceSchema
        self.sourceBytesSHA256 = sourceBytesSHA256
        self.sourceByteCount = sourceByteCount
    }
}

public struct WorkspaceLoadResult: Equatable, Sendable {
    public let state: WorkspaceState
    public let provenance: WorkspaceLoadProvenance
    public let consistencyIssues: [WorkspaceConsistencyIssue]

    public init(
        state: WorkspaceState,
        provenance: WorkspaceLoadProvenance,
        consistencyIssues: [WorkspaceConsistencyIssue]
    ) {
        self.state = state
        self.provenance = provenance
        self.consistencyIssues = consistencyIssues
    }
}

public struct WorkspaceSaveReceipt: Equatable, Sendable {
    public let workspaceRevision: Int64
    public let persistedDraft: PersistedDraftReceipt?

    public init(workspaceRevision: Int64, persistedDraft: PersistedDraftReceipt?) {
        self.workspaceRevision = workspaceRevision
        self.persistedDraft = persistedDraft
    }
}

public enum WorkspaceCommittedOperation: Equatable, Sendable {
    case save(WorkspaceSaveReceipt)
    case restore(WorkspaceRestoreOutcome)
}

public struct WorkspaceRawSourceIdentity: Equatable, Codable, Sendable {
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public enum WorkspaceRollbackArtifact: Equatable, Sendable {
    case file(URL, WorkspaceRawSourceIdentity)
    case nonePreviousSourceAbsent
}

public struct WorkspaceRestoreOutcome: Equatable, Sendable {
    public let receipt: WorkspaceSaveReceipt
    public let rollback: WorkspaceRollbackArtifact

    public init(receipt: WorkspaceSaveReceipt, rollback: WorkspaceRollbackArtifact) {
        self.receipt = receipt
        self.rollback = rollback
    }
}

public struct WorkspacePendingCommitArtifacts: Equatable, Sendable {
    public let rollback: WorkspaceRollbackArtifact?

    public init(rollback: WorkspaceRollbackArtifact? = nil) {
        self.rollback = rollback
    }
}

public enum WorkspaceCommitReconciliation: Equatable, Sendable {
    case committed(WorkspaceCommittedOperation)
    case notCommitted(WorkspacePendingCommitArtifacts)
    case sourceChanged(WorkspacePendingCommitArtifacts)
    case stillPending(WorkspacePendingCommitArtifacts)
}

public enum WorkspaceDirectCommitFailure: Error, Equatable, Sendable {
    case sourceChanged(WorkspacePendingCommitArtifacts)
}

public enum WorkspaceDraftPersistenceVerification: Equatable, Sendable {
    case verified(PersistedDraftReceipt)
    case notPersisted
    case sourceChanged
    case unreadableUnknown
}

public enum WorkspaceReloadedSource: Equatable, Sendable {
    case absent
    case valid(WorkspaceLoadResult)
    case opaqueInvalid(WorkspaceRawSourceIdentity)
    case unreadableUnknown
}

public struct WorkspaceRawRecoveryArtifact: Equatable, Sendable {
    public let rawData: Data
    public let identity: WorkspaceRawSourceIdentity

    public init(rawData: Data, identity: WorkspaceRawSourceIdentity) {
        self.rawData = rawData
        self.identity = identity
    }
}

public enum WorkspacePersistenceError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchema(Int)
    case invalidWorkspace
    case atomicWriteFailed
    case commitUncertain
    case missingDocument
    case invalidManifest
    case invalidSnapshot
    case invalidJournal
    case invalidDraftContext
    case invalidRestoreCapability
    case restoreBindingMismatch
    case rollbackWriteFailed
}

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    // V5 persists source-agnostic snapshots and block-level evidence. V4 is
    // migrated on read; older app builds cannot open a V5 workspace and must
    // not be used as writers after this schema is adopted.
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var state: WorkspaceState

    public init(schemaVersion: Int = currentSchemaVersion, state: WorkspaceState) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}
