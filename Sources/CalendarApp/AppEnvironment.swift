import CalendarDomain
import CalendarPersistence
import Foundation
import JellyMCP
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
    /// The one text model every AI follow-up uses; routed by 摘要设置.
    let textModel: any TextModelGenerating
    let inspirationFollowUp: InspirationFollowUpService
    let captureService: InspirationCaptureService
    let quickCapture: QuickCaptureCoordinator
    let reminderSync: ReminderSyncService
    /// Nil only when MCP is explicitly disabled for this run (acceptance tests).
    let mcpController: MCPServiceController?

    var whisperModelDirectory: URL {
        dataURLs.root.appendingPathComponent("Models/WhisperKit", isDirectory: true)
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) throws -> AppEnvironment {
        let dataURLs = try AppDataDirectoryResolver.resolve(
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
            transcriber: RoutingMaterialTranscriber(
                settings: TranscriptionSettingsReader(
                    settings: digestSettingsStore,
                    credentials: digestCredentialStore
                ),
                whisper: WhisperKitMaterialTranscriber(modelDirectory: whisperDirectory)
            ),
            summarizer: HierarchicalMaterialSummarizer(
                base: RoutingMaterialSummarizer(
                    settings: digestSettingsStore,
                    http: OpenAICompatibleMaterialSummarizer(
                        settings: digestSettingsStore,
                        credentials: digestCredentialStore
                    ),
                    local: LocalRuntimeMaterialSummarizer(settings: digestSettingsStore)
                )
            )
        )
        let textModel = RoutingTextModel(settings: digestSettingsStore, credentials: digestCredentialStore)
        let followUp = InspirationFollowUpService(
            store: store,
            model: textModel,
            autoExpandEnabled: { digestSettingsStore.autoExpandInspirations }
        )
        let captureService = InspirationCaptureService(store: store, followUp: followUp)
        let mcpController: MCPServiceController?
        if environment["JELLY_MCP_DISABLED"]?.trimmingCharacters(in: .whitespaces) == "1" {
            mcpController = nil
        } else {
            mcpController = MCPServiceController(
                gateway: JellyMCPCalGateway(store: store),
                endpointFileURL: dataURLs.mcpEndpoint
            )
        }
        return AppEnvironment(
            store: store,
            dataURLs: dataURLs,
            searchIndex: WorkspaceSearchIndex(fileURL: dataURLs.searchIndex),
            features: .production,
            materialDigestOperator: coordinator,
            digestSettingsStore: digestSettingsStore,
            digestCredentialStore: digestCredentialStore,
            decompositionPlanner: LiveDecompositionPlanner.make(),
            textModel: textModel,
            inspirationFollowUp: followUp,
            captureService: captureService,
            quickCapture: QuickCaptureCoordinator(
                captureService: captureService,
                settings: QuickCaptureSettings(defaults: digestSettingsStore.defaultsForCompanionSettings)
            ),
            reminderSync: ReminderSyncService(
                store: store,
                gateway: EventKitReminderGateway(),
                mappingURL: dataURLs.root.appendingPathComponent("reminder-sync.json"),
                settings: ReminderSyncSettings(defaults: digestSettingsStore.defaultsForCompanionSettings)
            ),
            mcpController: mcpController
        )
    }

    /// Global shortcut, Services menu and other services that must run
    /// whether or not the main window is open. Safe to call repeatedly.
    func startBackgroundServices() {
        quickCapture.start()
        reminderSync.start()
    }

    static func loadLive(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) -> Result<AppEnvironment, Error> {
        Result {
            try live(
                environment: environment,
                fileManager: fileManager,
                defaultApplicationSupportURL: defaultApplicationSupportURL
            )
        }
    }
}
