import CalendarDomain
import CalendarPersistence
import Foundation
import WorkspaceDomain

@MainActor
struct AppEnvironment {
    let store: WorkspaceStore
    let dataURLs: AppDataURLs
    let searchIndex: WorkspaceSearchIndex
    /// The production application stays calendar-only until a module has its
    /// complete real loop. Feature state is deliberately not user preference data.
    let features: WorkspaceFeatures
    let decompositionPlanner: any DecompositionPlanning

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> AppEnvironment {
        let dataURLs = try AppDataDirectoryResolver.resolve(
            environment: environment,
            fileManager: fileManager
        )
        let uncategorizedID = UUID()
        let calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: Date())
        let seed = WorkspaceState.empty(calendar: calendar)
        let repository = JSONWorkspaceRepository(
            documentURL: dataURLs.mainDocument,
            seed: { seed },
            snapshotDirectoryURL: dataURLs.migrationSnapshotDirectory,
            recoveryManifestURL: dataURLs.recoveryManifest
        )
        let journal = DraftJournalRepository(fileURL: dataURLs.draftJournal)
        return AppEnvironment(
            store: WorkspaceStore(initialState: seed, repository: repository, journal: journal),
            dataURLs: dataURLs,
            searchIndex: WorkspaceSearchIndex(fileURL: dataURLs.searchIndex),
            features: .production,
            decompositionPlanner: LiveDecompositionPlanner.make()
        )
    }

    static func loadLive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Result<AppEnvironment, Error> {
        Result { try live(environment: environment, fileManager: fileManager) }
    }
}
