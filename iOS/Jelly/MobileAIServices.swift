import Foundation
import Observation
import WorkspaceDomain

/// Assemblies are local only. Reading a source, calling a model, or downloading
/// Whisper begins only from the user's corresponding action in the views below.
@MainActor
@Observable
final class MobileAIServices {
    let settings: DigestSettingsStore
    let credentials: any DigestCredentialStoring
    let digest: MaterialDigestCoordinator
    let planner: any DecompositionPlanning
    /// Same follow-ups as the Mac: expansion, perspective questions, synthesis.
    let followUp: InspirationFollowUpService
    private(set) var isConfigured: Bool
    private(set) var hasSavedCredential: Bool

    init(
        store: WorkspaceStore,
        rootURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let settings = DigestSettingsStore(defaults: try DigestSettingsDefaults.resolve(
            environment: environment, dataRoot: rootURL
        ))
        let credentials = KeychainDigestCredentialStore(service: DigestCredentialService.resolve(
            environment: environment, dataRoot: rootURL
        ))
        let modelDirectory = rootURL.appendingPathComponent("Models/WhisperKit", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let client = MaterialHTTPClient()
        self.settings = settings
        self.credentials = credentials
        let textModel = RoutingTextModel(settings: settings, credentials: credentials)
        planner = SettingsRoutedDecompositionPlanner(textModel: textModel)
        followUp = InspirationFollowUpService(
            store: store,
            model: textModel,
            autoExpandEnabled: { settings.autoExpandInspirations }
        )
        hasSavedCredential = credentials.isConfigured
        isConfigured = DigestRuntimeConfiguration.isConfigured(
            endpoint: settings.endpoint, model: settings.model, secret: try? credentials.load()
        )
        digest = MaterialDigestCoordinator(
            store: store,
            acquirer: RoutedMaterialAcquirer(client: client),
            audioDownloader: TemporaryMaterialAudioDownloader(client: client),
            transcriber: RoutingMaterialTranscriber(
                settings: TranscriptionSettingsReader(settings: settings, credentials: credentials),
                whisper: WhisperKitMaterialTranscriber(modelDirectory: modelDirectory),
                whisperInstalled: false
            ),
            summarizer: HierarchicalMaterialSummarizer(
                base: RoutingMaterialSummarizer(
                    settings: settings,
                    http: OpenAICompatibleMaterialSummarizer(settings: settings, credentials: credentials),
                    local: LocalRuntimeMaterialSummarizer(settings: settings)
                )
            )
        )
    }

    func refreshConfiguration() {
        hasSavedCredential = credentials.isConfigured
        isConfigured = DigestRuntimeConfiguration.isConfigured(
            endpoint: settings.endpoint, model: settings.model, secret: try? credentials.load()
        )
    }

    func save(
        endpoint: String,
        model: String,
        newSecret: String,
        service: DigestSummaryService
    ) throws {
        guard DigestSettingsNormalization.endpoint(endpoint) != nil,
              DigestSettingsNormalization.model(model) != nil else {
            throw MobileAIConfigurationError.invalidSettings
        }
        if !newSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try credentials.save(newSecret)
        }
        guard settings.save(endpoint: endpoint, model: model) else {
            throw MobileAIConfigurationError.invalidSettings
        }
        settings.setSummarySource(.service)
        settings.setSummaryService(service)
        refreshConfiguration()
    }

    func deleteCredential() throws {
        try credentials.delete()
        refreshConfiguration()
    }
}

enum MobileAIConfigurationError: Error { case invalidSettings }
