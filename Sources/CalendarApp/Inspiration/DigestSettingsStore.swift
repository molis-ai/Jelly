import Foundation
import Observation

enum DigestSettingsNormalization {
    static func endpoint(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        components.scheme = "https"
        guard let normalized = components.url?.absoluteString else { return nil }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func model(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DigestSummaryService: String, CaseIterable, Identifiable, Sendable {
    case minimax
    case deepseek
    case kimi
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimax: "MiniMax"
        case .deepseek: "DeepSeek"
        case .kimi: "Kimi"
        case .custom: "自定义"
        }
    }

    var defaultEndpoint: String? {
        switch self {
        case .minimax: "https://api.minimaxi.com/v1"
        case .deepseek: "https://api.deepseek.com"
        case .kimi: "https://api.moonshot.cn/v1"
        case .custom: nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .minimax: "MiniMax-M3"
        case .deepseek: "deepseek-chat"
        case .kimi: "kimi-k2"
        case .custom: nil
        }
    }

    var allowsSpeechUpload: Bool { self == .minimax }
}

enum DigestSummarySource: String, Sendable {
    case service
    case localRuntime
}

enum LocalSummaryRuntime: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var commandName: String { rawValue }
}

enum DigestRuntimeConfiguration {
    static func isConfigured(endpoint: String, model: String, secret: String?) -> Bool {
        DigestSettingsNormalization.endpoint(endpoint) != nil
            && DigestSettingsNormalization.model(model) != nil
            && !(secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DigestSettingsDefaults {
    enum ResolutionError: Error { case unavailable }

    static func resolve(environment: [String: String], dataRoot: URL) throws -> UserDefaults {
        let namespace = DigestCredentialService.resolve(
            environment: environment,
            dataRoot: dataRoot
        )
        guard namespace != DigestCredentialService.production else { return .standard }
        guard let defaults = UserDefaults(suiteName: namespace) else {
            throw ResolutionError.unavailable
        }
        return defaults
    }
}

@Observable
final class DigestSettingsStore {
    static let endpointKey = "digest.endpoint.v1"
    static let modelKey = "digest.model.v1"
    static let allowCloudTranscriptionKey = "digest.transcription.allowCloud.v1"
    static let allowLocalWhisperKey = "digest.transcription.allowWhisper.v1"
    static let summarySourceKey = "digest.summary.source.v1"
    static let summaryServiceKey = "digest.summary.service.v1"
    static let localRuntimeKey = "digest.summary.runtime.v1"
    static let autoExpandInspirationsKey = "digest.inspiration.autoExpand.v1"

    private let defaults: UserDefaults
    private(set) var endpoint: String
    private(set) var model: String
    private(set) var allowCloudTranscription: Bool
    private(set) var allowLocalWhisper: Bool
    private(set) var summarySource: DigestSummarySource
    private(set) var summaryService: DigestSummaryService
    private(set) var localRuntime: LocalSummaryRuntime
    /// 收下纯文本灵感后自动请模型补一句。只在模型已配置时生效。
    private(set) var autoExpandInspirations: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEndpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        endpoint = storedEndpoint
        model = defaults.string(forKey: Self.modelKey) ?? ""
        allowCloudTranscription = defaults.bool(forKey: Self.allowCloudTranscriptionKey)
        allowLocalWhisper = defaults.bool(forKey: Self.allowLocalWhisperKey)
        summarySource = DigestSummarySource(rawValue: defaults.string(forKey: Self.summarySourceKey) ?? "") ?? .service
        summaryService = DigestSummaryService(rawValue: defaults.string(forKey: Self.summaryServiceKey) ?? "")
            ?? Self.inferredService(endpoint: storedEndpoint)
        localRuntime = LocalSummaryRuntime(rawValue: defaults.string(forKey: Self.localRuntimeKey) ?? "") ?? .codex
        autoExpandInspirations = defaults.object(forKey: Self.autoExpandInspirationsKey) as? Bool ?? true
    }

    private static func inferredService(endpoint: String) -> DigestSummaryService {
        let host = URL(string: endpoint)?.host?.lowercased() ?? ""
        if host.contains("minimaxi.com") || host.contains("minimax.io") { return .minimax }
        if host.contains("deepseek.com") { return .deepseek }
        if host.contains("moonshot.cn") { return .kimi }
        return endpoint.isEmpty ? .minimax : .custom
    }

    @discardableResult
    func save(endpoint rawEndpoint: String, model rawModel: String) -> Bool {
        guard let normalizedEndpoint = DigestSettingsNormalization.endpoint(rawEndpoint),
              let normalizedModel = DigestSettingsNormalization.model(rawModel)
        else { return false }
        defaults.set(normalizedEndpoint, forKey: Self.endpointKey)
        defaults.set(normalizedModel, forKey: Self.modelKey)
        endpoint = normalizedEndpoint
        model = normalizedModel
        return true
    }

    func setAllowCloudTranscription(_ allowed: Bool) {
        defaults.set(allowed, forKey: Self.allowCloudTranscriptionKey)
        allowCloudTranscription = allowed
    }

    func setAllowLocalWhisper(_ allowed: Bool) {
        defaults.set(allowed, forKey: Self.allowLocalWhisperKey)
        allowLocalWhisper = allowed
    }

    func setSummarySource(_ source: DigestSummarySource) {
        defaults.set(source.rawValue, forKey: Self.summarySourceKey)
        summarySource = source
    }

    func setSummaryService(_ service: DigestSummaryService) {
        defaults.set(service.rawValue, forKey: Self.summaryServiceKey)
        summaryService = service
    }

    func setLocalRuntime(_ runtime: LocalSummaryRuntime) {
        defaults.set(runtime.rawValue, forKey: Self.localRuntimeKey)
        localRuntime = runtime
    }

    func setAutoExpandInspirations(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoExpandInspirationsKey)
        autoExpandInspirations = enabled
    }

    var cloudSpeechUploadEnabled: Bool {
        allowCloudTranscription && summarySource == .service && summaryService.allowsSpeechUpload
    }
}
