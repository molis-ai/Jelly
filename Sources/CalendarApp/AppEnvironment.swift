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
    let materialDigestOperator: (any MaterialDigestOperating)?
    let digestSettingsStore: DigestSettingsStore
    let digestCredentialStore: any DigestCredentialStoring
    let decompositionPlanner: any DecompositionPlanning

    var whisperModelDirectory: URL {
        dataURLs.root.appendingPathComponent("Models/WhisperKit", isDirectory: true)
    }

    static func live(
        profile: AppDataProfile? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) throws -> AppEnvironment {
        let resolvedProfile = try profile ?? AppDataProfile.bundled()
        let dataURLs = try AppDataDirectoryResolver.resolve(
            profile: resolvedProfile,
            environment: environment,
            fileManager: fileManager,
            defaultApplicationSupportURL: defaultApplicationSupportURL
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
        let whisperDirectory = dataURLs.root.appendingPathComponent("Models/WhisperKit", isDirectory: true)
        try fileManager.createDirectory(at: whisperDirectory, withIntermediateDirectories: true)
        let store = WorkspaceStore(initialState: seed, repository: repository, journal: journal)
        let digestSettingsStore = DigestSettingsStore(defaults: try DigestSettingsDefaults.resolve(
            environment: environment,
            dataRoot: dataURLs.root
        ))
        let digestCredentialStore = KeychainDigestCredentialStore(
            service: DigestCredentialService.resolve(
                environment: environment,
                dataRoot: dataURLs.root
            )
        )
        let httpClient = MaterialHTTPClient()
        let coordinator = MaterialDigestCoordinator(
            store: store,
            acquirer: RoutedMaterialAcquirer(client: httpClient),
            audioDownloader: TemporaryMaterialAudioDownloader(client: httpClient),
            transcriber: WhisperKitMaterialTranscriber(modelDirectory: whisperDirectory),
            summarizer: HierarchicalMaterialSummarizer(
                base: OpenAICompatibleMaterialSummarizer(
                    settings: digestSettingsStore,
                    credentials: digestCredentialStore
                )
            )
        )
        return AppEnvironment(
            store: store,
            dataURLs: dataURLs,
            searchIndex: WorkspaceSearchIndex(fileURL: dataURLs.searchIndex),
            features: .production,
            materialDigestOperator: coordinator,
            digestSettingsStore: digestSettingsStore,
            digestCredentialStore: digestCredentialStore,
            decompositionPlanner: LiveDecompositionPlanner.make()
        )
    }

    static func loadLive(
        profile: AppDataProfile? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) -> Result<AppEnvironment, Error> {
        Result {
            try live(
                profile: profile,
                environment: environment,
                fileManager: fileManager,
                defaultApplicationSupportURL: defaultApplicationSupportURL
            )
        }
    }
}
