import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@MainActor
func makeReadyStore(
    initialState: CalendarState
) async throws -> (WorkspaceStore, InMemoryWorkspaceRepository) {
    let repository = InMemoryWorkspaceRepository(initialState: initialState)
    let store = WorkspaceStore(initialState: .empty(calendar: initialState), repository: repository)
    await store.load()
    try #require(store.phase == .ready)
    return (store, repository)
}

@MainActor
extension WorkspaceStore {
    convenience init(initialState: CalendarState, repository: any WorkspaceRepository) {
        self.init(initialState: .empty(calendar: initialState), repository: repository)
    }
}

func makeEmptyState() -> CalendarState {
    CalendarState.empty(
        uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
        now: .distantPast
    )
}

func makeCategory(name: String) -> CalendarCategory {
    CalendarCategory(
        id: UUID(), name: name, colorHex: "#007AFF", sortIndex: 1,
        createdAt: .distantPast, updatedAt: .distantPast
    )
}

func makeItem(
    categoryID: UUID,
    title: String = "测试事项",
    date: CalendarDate = CalendarDate(year: 2026, month: 8, day: 3)!
) throws -> CalendarItem {
    try CalendarItem(
        id: UUID(), kind: .task, title: title, categoryID: categoryID,
        schedule: try CalendarSchedule(
            startDate: date,
            endDate: date,
            startTime: nil,
            endTime: nil
        ),
        completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
    )
}

func makeStateWithOneItem() throws -> CalendarState {
    var state = makeEmptyState()
    let item = try makeItem(categoryID: state.uncategorizedID)
    state.items[item.id] = item
    return state
}

func makeCategoryReferenceFixture() throws -> (
    state: CalendarState,
    deletedCategoryID: UUID,
    targetCategoryID: UUID
) {
    var state = makeEmptyState()
    let deleted = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    let target = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
    state.categories[deleted] = CalendarCategory(
        id: deleted, name: "待删除", colorHex: "#FF3B30", sortIndex: 1,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    state.categories[target] = CalendarCategory(
        id: target, name: "迁移目标", colorHex: "#34C759", sortIndex: 2,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    let date = CalendarDate(year: 2026, month: 8, day: 3)!
    let item = try makeItem(categoryID: deleted, date: date)
    state.items[item.id] = item
    let series = try WeeklySeries(
        id: UUID(), kind: .task, title: "重复事项", categoryID: deleted,
        ruleStartDate: date, recurrenceEndDate: nil, weekdays: [.monday],
        durationDays: 1, startTime: nil, endTime: nil,
        createdAt: .distantPast, updatedAt: .distantPast
    )
    state.recurrence.series[series.id] = series
    let key = OccurrenceKey(seriesID: series.id, originalDate: date)
    state.recurrence.exceptions[key] = .modified(.init(
        displayedSchedule: try CalendarSchedule(
            startDate: date,
            endDate: date,
            startTime: nil,
            endTime: nil
        ),
        title: "改期事项", kind: .task, categoryID: deleted
    ))
    return (state, deleted, target)
}

func makeBackupFile(for state: CalendarState) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CalendarAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("backup.json")
    try WorkspaceDocumentCodec.encode(.empty(calendar: state)).write(to: source)
    return source
}

actor InMemoryWorkspaceRepository: WorkspaceRepository {
    private var workspace: WorkspaceState
    private(set) var saveCount = 0
    private var failSave = false
    private var suspendLoad = false
    private var suspendSave = false
    private var loadStarted = false
    private var saveStarted = false
    private var loadStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var saveContinuations: [CheckedContinuation<Void, Never>] = []

    init(initialState: CalendarState) {
        workspace = .empty(calendar: initialState)
    }

    init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    var persistedState: CalendarState { workspace.calendar }

    func load() async throws -> WorkspaceLoadResult {
        if suspendLoad {
            signalLoadStarted()
            await waitForLoadResume()
        }
        return loadResult()
    }

    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt {
        if suspendSave {
            signalSaveStarted()
            await waitForSaveResume()
        }
        if failSave {
            failSave = false
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        workspace = state
        saveCount += 1
        return .init(
            workspaceRevision: state.revision,
            persistedDraft: draft.map {
                .init(
                    noteID: $0.noteID,
                    editSessionID: $0.editSessionID,
                    draftGeneration: $0.draftGeneration,
                    noteSnapshotChecksum: $0.noteSnapshotChecksum,
                    persistedNoteRevision: $0.persistedNoteRevision
                )
            }
        )
    }

    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws -> WorkspaceDraftPersistenceVerification {
        .notPersisted
    }

    func prepareRestore(_ preview: WorkspaceRestorePreview, rollbackDirectoryURL: URL) async throws -> PreparedWorkspaceRestore {
        throw WorkspacePersistenceError.invalidRestoreCapability
    }

    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool { false }

    func commitRestore(_ prepared: PreparedWorkspaceRestore, state: WorkspaceState) async throws -> WorkspaceRestoreOutcome {
        throw WorkspacePersistenceError.invalidRestoreCapability
    }

    func currentDocumentData() async throws -> Data { try WorkspaceDocumentCodec.encode(workspace) }

    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource { .valid(loadResult()) }

    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact {
        throw WorkspacePersistenceError.invalidDocument
    }

    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation { .stillPending(.init()) }

    func failNextSave() { failSave = true }
    func suspendNextLoad() { suspendLoad = true }
    func suspendNextSave() { suspendSave = true }

    func waitForLoadToStart() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { loadStartWaiters.append($0) }
    }

    func waitForSaveToStart() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { saveStartWaiters.append($0) }
    }

    func resumeLoad() {
        suspendLoad = false
        let waiting = loadContinuations
        loadContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func resumeSave() {
        suspendSave = false
        let waiting = saveContinuations
        saveContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func loadResult() -> WorkspaceLoadResult {
        .init(
            state: workspace,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "test", sourceByteCount: 0),
            consistencyIssues: []
        )
    }

    private func signalLoadStarted() {
        loadStarted = true
        let waiting = loadStartWaiters
        loadStartWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func signalSaveStarted() {
        saveStarted = true
        let waiting = saveStartWaiters
        saveStartWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func waitForLoadResume() async {
        await withCheckedContinuation { loadContinuations.append($0) }
    }

    private func waitForSaveResume() async {
        await withCheckedContinuation { saveContinuations.append($0) }
    }
}
